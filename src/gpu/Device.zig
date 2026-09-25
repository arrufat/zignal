//! Vulkan compute device that runs the SPIR-V kernels in `kernels/`.
//!
//! The Vulkan loader is opened at runtime, so binaries keep working on machines without a GPU:
//! `init` returns `error.GpuUnavailable` when there is no loader, no device with a compute
//! queue, or a required feature (Vulkan 1.2, buffer device address, 64-bit shader ints) is
//! missing. Buffers are host-visible and coherent; on integrated GPUs they are also
//! device-local, so uploads and downloads are plain memcpys.
//!
//! A `Device` owns one command buffer and one set of staging buffers, so it is not thread-safe;
//! create one per thread.
const std = @import("std");
const parallel = @import("../parallel.zig");
const builtin = @import("builtin");
const build_options = @import("build_options");
const vk = @import("vulkan.zig");
const dynlib = @import("../dynlib.zig");
const params = @import("kernels/params.zig");
const matrix = @import("../matrix.zig");
const Matrix = matrix.Matrix;
const MatrixError = matrix.Error;
const Allocator = std.mem.Allocator;

const Device = @This();

/// The Vulkan loader is opened at runtime like the system codecs (see `dynlib.zig`).
pub const supported = build_options.gpu and dynlib.supported;

pub const Error = error{GpuUnavailable} || vk.Error;

// SPIR-V words must be 4-byte aligned; `@embedFile` only guarantees byte alignment.
const gemm_spv: [gemm_spv_bytes.len]u8 align(@alignOf(u32)) = gemm_spv_bytes.*;
const gemm_spv_bytes = @embedFile("gemm.spv");

/// Only `vkGetInstanceProcAddr` comes from the loader; every other entry point is resolved
/// through it in `vk.Functions`.
const Vulkan = dynlib.Library(struct { vkGetInstanceProcAddr: vk.GetInstanceProcAddr }, switch (builtin.os.tag) {
    .macos => dynlib.macosNames("libvulkan.1.dylib") ++ dynlib.macosNames("libMoltenVK.dylib"),
    else => &.{ "libvulkan.so.1", "libvulkan.so" },
}, error.GpuUnavailable);

f: vk.Functions,
instance: vk.Instance,
dev: vk.Device,
queue: vk.Queue,
props: vk.PhysicalDeviceProperties,
mem_props: vk.PhysicalDeviceMemoryProperties,
pool: vk.Handle,
cb: vk.CommandBuffer,
fence: vk.Handle,
gemm_pipeline: Pipeline,
/// Reusable staging slots for kernel operands: A, B, C.
buffers: [3]Buffer,

pub fn init() Error!Device {
    return if (supported) initSupported() else error.GpuUnavailable;
}

pub fn deinit(self: *Device) void {
    if (supported) self.deinitSupported();
}

/// Driver-reported device name, e.g. "Intel(R) Graphics (LNL)".
pub fn name(self: *const Device) []const u8 {
    return std.mem.sliceTo(&self.props.device_name, 0);
}

/// GPU counterpart of `Matrix(f32).gemm`: C = alpha * op(A) * op(B) + beta * C, where
/// `c == null` stands for the zero matrix. The result is allocated with `a.allocator`.
pub fn gemm(
    self: *Device,
    a: Matrix(f32),
    trans_a: bool,
    b: Matrix(f32),
    trans_b: bool,
    alpha: f32,
    beta: f32,
    c: ?Matrix(f32),
) (Error || MatrixError || Allocator.Error)!Matrix(f32) {
    const m = if (trans_a) a.cols else a.rows;
    const k = if (trans_a) a.rows else a.cols;
    const k_b = if (trans_b) b.cols else b.rows;
    const n = if (trans_b) b.rows else b.cols;
    if (k != k_b) return error.DimensionMismatch;
    if (c) |c_mat| if (c_mat.rows != m or c_mat.cols != n) return error.DimensionMismatch;
    // Vulkan rejects zero-sized buffers; the CPU path handles degenerate shapes.
    if (m == 0 or n == 0 or k == 0) return a.gemm(parallel.inline_io, trans_a, b, trans_b, alpha, beta, c);

    var result: Matrix(f32) = try .init(a.allocator, m, n);
    errdefer result.deinit();

    const buf_a = &self.buffers[0];
    const buf_b = &self.buffers[1];
    const buf_c = &self.buffers[2];
    try buf_a.ensure(self, a.items.len * @sizeOf(f32));
    try buf_b.ensure(self, b.items.len * @sizeOf(f32));
    try buf_c.ensure(self, result.items.len * @sizeOf(f32));
    @memcpy(buf_a.slice(f32, a.items.len), a.items);
    @memcpy(buf_b.slice(f32, b.items.len), b.items);
    const accumulate = c != null and beta != 0;
    if (accumulate) @memcpy(buf_c.slice(f32, result.items.len), c.?.items);

    const push: params.Gemm = .{
        .a = buf_a.address,
        .b = buf_b.address,
        .c = buf_c.address,
        .m = m,
        .n = n,
        .k = k,
        .flags = (if (trans_a) params.Gemm.trans_a else 0) | (if (trans_b) params.Gemm.trans_b else 0),
        .alpha = alpha,
        .beta = if (accumulate) beta else 0,
    };
    const blk = params.gemm_block;
    try self.dispatch(self.gemm_pipeline, &push, (n + blk - 1) / blk, (m + blk - 1) / blk);
    @memcpy(result.items, buf_c.slice(f32, result.items.len));
    return result;
}

fn initSupported() Error!Device {
    var f: vk.Functions = .{ .get_instance_proc_addr = (try Vulkan.get()).vkGetInstanceProcAddr };
    f.loadGlobal() catch return error.GpuUnavailable;
    const instance = try createInstance(&f);
    f.loadInstance(instance) catch return error.GpuUnavailable;
    errdefer f.destroy_instance(instance, null);

    const pick = pickPhysicalDevice(&f, instance) orelse return error.GpuUnavailable;

    var bda: vk.PhysicalDeviceBufferDeviceAddressFeatures = .{ .buffer_device_address = 1 };
    const features: vk.PhysicalDeviceFeatures = .{ .shader_int64 = 1 };
    const priority = [_]f32{1.0};
    const queue_info = [_]vk.DeviceQueueCreateInfo{.{ .queue_family_index = pick.family, .queue_priorities = &priority }};
    var dev_opt: ?vk.Device = null;
    vk.check(f.create_device(pick.phys, &.{
        .p_next = &bda,
        .queue_create_info_count = 1,
        .queue_create_infos = &queue_info,
        .enabled_features = &features,
    }, null, &dev_opt)) catch return error.GpuUnavailable;
    const dev = dev_opt.?;
    errdefer f.destroy_device(dev, null);

    var queue_opt: ?vk.Queue = null;
    f.get_device_queue(dev, pick.family, 0, &queue_opt);
    var mem_props: vk.PhysicalDeviceMemoryProperties = undefined;
    f.get_physical_device_memory_properties(pick.phys, &mem_props);

    var pool: vk.Handle = .null;
    try vk.check(f.create_command_pool(dev, &.{
        .flags = vk.command_pool_create_reset_command_buffer_bit,
        .queue_family_index = pick.family,
    }, null, &pool));
    errdefer f.destroy_command_pool(dev, pool, null);
    var cbs: [1]?vk.CommandBuffer = .{null};
    try vk.check(f.allocate_command_buffers(dev, &.{ .command_pool = pool }, &cbs));
    var fence: vk.Handle = .null;
    try vk.check(f.create_fence(dev, &.{}, null, &fence));
    errdefer f.destroy_fence(dev, fence, null);

    var self: Device = .{
        .f = f,
        .instance = instance,
        .dev = dev,
        .queue = queue_opt.?,
        .props = pick.props,
        .mem_props = mem_props,
        .pool = pool,
        .cb = cbs[0].?,
        .fence = fence,
        .gemm_pipeline = undefined,
        .buffers = @splat(.{}),
    };
    self.gemm_pipeline = try Pipeline.create(&self, &gemm_spv, @sizeOf(params.Gemm));
    return self;
}

fn deinitSupported(self: *Device) void {
    _ = self.f.device_wait_idle(self.dev);
    for (&self.buffers) |*buffer| buffer.destroy(self);
    self.gemm_pipeline.destroy(self);
    self.f.destroy_fence(self.dev, self.fence, null);
    self.f.destroy_command_pool(self.dev, self.pool, null);
    self.f.destroy_device(self.dev, null);
    self.f.destroy_instance(self.instance, null);
}

fn createInstance(f: *vk.Functions) Error!vk.Instance {
    const app: vk.ApplicationInfo = .{ .application_name = "zignal", .api_version = vk.api_version_1_2 };
    var instance: ?vk.Instance = null;
    if (builtin.os.tag == .macos) {
        // Recent loaders hide MoltenVK unless portability enumeration is requested.
        const exts = [_][*:0]const u8{"VK_KHR_portability_enumeration"};
        const portability_bit: u32 = 0x1;
        if (f.create_instance(&.{
            .flags = portability_bit,
            .application_info = &app,
            .enabled_extension_count = exts.len,
            .enabled_extension_names = &exts,
        }, null, &instance) == .success) return instance.?;
    }
    vk.check(f.create_instance(&.{ .application_info = &app }, null, &instance)) catch return error.GpuUnavailable;
    return instance.?;
}

const Pick = struct { phys: vk.PhysicalDevice, family: u32, props: vk.PhysicalDeviceProperties };

/// Highest-ranked device (discrete > integrated > virtual > CPU) that has a compute queue and
/// the features the kernels rely on.
fn pickPhysicalDevice(f: *vk.Functions, instance: vk.Instance) ?Pick {
    var count: u32 = 0;
    if (f.enumerate_physical_devices(instance, &count, null) != .success or count == 0) return null;
    var devices: [8]vk.PhysicalDevice = undefined;
    count = @min(count, devices.len);
    if (f.enumerate_physical_devices(instance, &count, &devices) != .success) return null;

    var best: ?Pick = null;
    var best_rank: u8 = 0;
    for (devices[0..count]) |phys| {
        var props: vk.PhysicalDeviceProperties = undefined;
        f.get_physical_device_properties(phys, &props);
        if (props.api_version < vk.api_version_1_2) continue;

        var bda: vk.PhysicalDeviceBufferDeviceAddressFeatures = .{};
        var features: vk.PhysicalDeviceFeatures2 = .{ .p_next = &bda };
        f.get_physical_device_features2(phys, &features);
        if (bda.buffer_device_address == 0 or features.features.shader_int64 == 0) continue;
        if (props.limits.max_compute_work_group_invocations < params.gemm_threads * params.gemm_threads) continue;

        const family = computeQueueFamily(f, phys) orelse continue;
        const rank: u8 = switch (props.device_type) {
            .discrete_gpu => 4,
            .integrated_gpu => 3,
            .virtual_gpu => 2,
            .cpu, .other => 1,
            _ => 1,
        };
        if (rank > best_rank) {
            best_rank = rank;
            best = .{ .phys = phys, .family = family, .props = props };
        }
    }
    return best;
}

fn computeQueueFamily(f: *vk.Functions, phys: vk.PhysicalDevice) ?u32 {
    var count: u32 = 0;
    f.get_physical_device_queue_family_properties(phys, &count, null);
    var families: [16]vk.QueueFamilyProperties = undefined;
    count = @min(count, families.len);
    f.get_physical_device_queue_family_properties(phys, &count, &families);
    for (families[0..count], 0..) |family, i| {
        if (family.queue_flags & vk.queue_compute_bit != 0) return @intCast(i);
    }
    return null;
}

/// Host-coherent memory type usable by `type_bits`, preferring device-local then host-cached.
fn pickMemoryType(self: *const Device, type_bits: u32) ?u32 {
    var best: ?u32 = null;
    var best_score: i32 = -1;
    for (self.mem_props.memory_types[0..self.mem_props.memory_type_count], 0..) |mem_type, i| {
        if (type_bits & (@as(u32, 1) << @intCast(i)) == 0) continue;
        const required = vk.memory_property_host_visible_bit | vk.memory_property_host_coherent_bit;
        if (mem_type.property_flags & required != required) continue;
        var score: i32 = 0;
        if (mem_type.property_flags & vk.memory_property_device_local_bit != 0) score += 2;
        if (mem_type.property_flags & vk.memory_property_host_cached_bit != 0) score += 1;
        if (score > best_score) {
            best_score = score;
            best = @intCast(i);
        }
    }
    return best;
}

/// Records one dispatch with host<->shader barriers, submits it and waits for completion.
fn dispatch(self: *Device, pipeline: Pipeline, push: *const anyopaque, groups_x: u32, groups_y: u32) Error!void {
    const f = &self.f;
    const cb = self.cb;
    try vk.check(f.reset_command_buffer(cb, 0));
    try vk.check(f.begin_command_buffer(cb, &.{ .flags = vk.command_buffer_usage_one_time_submit_bit }));
    const before = [_]vk.MemoryBarrier{.{ .src_access_mask = vk.access_host_write_bit, .dst_access_mask = vk.access_shader_read_bit }};
    f.cmd_pipeline_barrier(cb, vk.pipeline_stage_host_bit, vk.pipeline_stage_compute_shader_bit, 0, 1, &before, 0, null, 0, null);
    f.cmd_bind_pipeline(cb, vk.pipeline_bind_point_compute, pipeline.pipeline);
    f.cmd_push_constants(cb, pipeline.layout, vk.shader_stage_compute_bit, 0, pipeline.push_size, push);
    f.cmd_dispatch(cb, groups_x, groups_y, 1);
    const after = [_]vk.MemoryBarrier{.{ .src_access_mask = vk.access_shader_write_bit, .dst_access_mask = vk.access_host_read_bit }};
    f.cmd_pipeline_barrier(cb, vk.pipeline_stage_compute_shader_bit, vk.pipeline_stage_host_bit, 0, 1, &after, 0, null, 0, null);
    try vk.check(f.end_command_buffer(cb));
    const cbs = [_]vk.CommandBuffer{cb};
    const submit = [_]vk.SubmitInfo{.{ .command_buffer_count = 1, .command_buffers = &cbs }};
    try vk.check(f.queue_submit(self.queue, 1, &submit, self.fence));
    try vk.check(f.wait_for_fences(self.dev, 1, @ptrCast(&self.fence), 1, std.math.maxInt(u64)));
    try vk.check(f.reset_fences(self.dev, 1, @ptrCast(&self.fence)));
}

const Pipeline = struct {
    module: vk.Handle,
    layout: vk.Handle,
    pipeline: vk.Handle,
    push_size: u32,

    fn create(d: *Device, spv: []align(@alignOf(u32)) const u8, push_size: u32) Error!Pipeline {
        const f = &d.f;
        var module: vk.Handle = .null;
        try vk.check(f.create_shader_module(d.dev, &.{ .code_size = spv.len, .code = @ptrCast(spv.ptr) }, null, &module));
        errdefer f.destroy_shader_module(d.dev, module, null);
        const ranges = [_]vk.PushConstantRange{.{ .stage_flags = vk.shader_stage_compute_bit, .offset = 0, .size = push_size }};
        var layout: vk.Handle = .null;
        try vk.check(f.create_pipeline_layout(d.dev, &.{ .push_constant_range_count = 1, .push_constant_ranges = &ranges }, null, &layout));
        errdefer f.destroy_pipeline_layout(d.dev, layout, null);
        const infos = [_]vk.ComputePipelineCreateInfo{.{
            .stage = .{ .stage = vk.shader_stage_compute_bit, .module = module, .name = "main" },
            .layout = layout,
        }};
        var pipelines: [1]vk.Handle = .{.null};
        try vk.check(f.create_compute_pipelines(d.dev, .null, 1, &infos, null, &pipelines));
        return .{ .module = module, .layout = layout, .pipeline = pipelines[0], .push_size = push_size };
    }

    fn destroy(self: *Pipeline, d: *Device) void {
        d.f.destroy_pipeline(d.dev, self.pipeline, null);
        d.f.destroy_pipeline_layout(d.dev, self.layout, null);
        d.f.destroy_shader_module(d.dev, self.module, null);
    }
};

/// Host-mapped storage buffer with a device address; grows on demand.
const Buffer = struct {
    buffer: vk.Handle = .null,
    memory: vk.Handle = .null,
    address: u64 = 0,
    map: [*]u8 = undefined,
    capacity: u64 = 0,

    fn slice(self: *const Buffer, comptime T: type, len: usize) []T {
        return @as([*]T, @ptrCast(@alignCast(self.map)))[0..len];
    }

    fn ensure(self: *Buffer, d: *Device, bytes: u64) Error!void {
        if (self.capacity >= bytes) return;
        self.destroy(d);
        const f = &d.f;
        var buffer: vk.Handle = .null;
        try vk.check(f.create_buffer(d.dev, &.{
            .size = bytes,
            .usage = vk.buffer_usage_storage_buffer_bit | vk.buffer_usage_shader_device_address_bit,
        }, null, &buffer));
        errdefer f.destroy_buffer(d.dev, buffer, null);
        var reqs: vk.MemoryRequirements = undefined;
        f.get_buffer_memory_requirements(d.dev, buffer, &reqs);
        const flags: vk.MemoryAllocateFlagsInfo = .{ .flags = vk.memory_allocate_device_address_bit };
        var memory: vk.Handle = .null;
        try vk.check(f.allocate_memory(d.dev, &.{
            .p_next = &flags,
            .allocation_size = reqs.size,
            .memory_type_index = d.pickMemoryType(reqs.memory_type_bits) orelse return error.GpuUnavailable,
        }, null, &memory));
        errdefer f.free_memory(d.dev, memory, null);
        try vk.check(f.bind_buffer_memory(d.dev, buffer, memory, 0));
        var mapped: ?*anyopaque = null;
        try vk.check(f.map_memory(d.dev, memory, 0, bytes, 0, &mapped));
        self.* = .{
            .buffer = buffer,
            .memory = memory,
            .address = f.get_buffer_device_address(d.dev, &.{ .buffer = buffer }),
            .map = @ptrCast(mapped.?),
            .capacity = bytes,
        };
    }

    fn destroy(self: *Buffer, d: *Device) void {
        if (self.buffer == .null) return;
        d.f.destroy_buffer(d.dev, self.buffer, null);
        d.f.free_memory(d.dev, self.memory, null);
        self.* = .{};
    }
};

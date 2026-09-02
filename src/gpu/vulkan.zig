//! Hand-declared subset of the Vulkan 1.2 API needed for compute dispatch.
//! Only functions and structs used by `Device` are declared; entry points are resolved at
//! runtime through `vkGetInstanceProcAddr`, so no import library is needed.
const std = @import("std");

/// Non-dispatchable handle (64-bit on every platform).
pub const Handle = enum(u64) { null = 0, _ };
pub const Instance = *opaque {};
pub const PhysicalDevice = *opaque {};
pub const Device = *opaque {};
pub const Queue = *opaque {};
pub const CommandBuffer = *opaque {};
pub const Bool32 = u32;
pub const Result = enum(i32) {
    success = 0,
    not_ready = 1,
    timeout = 2,
    error_out_of_host_memory = -1,
    error_out_of_device_memory = -2,
    error_initialization_failed = -3,
    error_device_lost = -4,
    error_feature_not_present = -8,
    error_incompatible_driver = -9,
    _,
};

pub const Error = error{ OutOfMemory, OutOfDeviceMemory, DeviceLost, VulkanError };

pub fn check(r: Result) Error!void {
    return switch (r) {
        .success => {},
        .error_out_of_host_memory => error.OutOfMemory,
        .error_out_of_device_memory => error.OutOfDeviceMemory,
        .error_device_lost => error.DeviceLost,
        else => error.VulkanError,
    };
}

pub fn makeApiVersion(major: u32, minor: u32) u32 {
    return (major << 22) | (minor << 12);
}
pub const api_version_1_2 = makeApiVersion(1, 2);

pub const StructureType = enum(i32) {
    application_info = 0,
    instance_create_info = 1,
    device_queue_create_info = 2,
    device_create_info = 3,
    submit_info = 4,
    memory_allocate_info = 5,
    fence_create_info = 8,
    buffer_create_info = 12,
    shader_module_create_info = 16,
    pipeline_shader_stage_create_info = 18,
    compute_pipeline_create_info = 29,
    pipeline_layout_create_info = 30,
    command_pool_create_info = 39,
    command_buffer_allocate_info = 40,
    command_buffer_begin_info = 42,
    memory_barrier = 46,
    physical_device_features_2 = 1000059000,
    memory_allocate_flags_info = 1000060000,
    physical_device_buffer_device_address_features = 1000244000,
    buffer_device_address_info = 1000244001,
};

pub const PhysicalDeviceType = enum(i32) { other = 0, integrated_gpu = 1, discrete_gpu = 2, virtual_gpu = 3, cpu = 4, _ };

// Flag bits
pub const queue_compute_bit: u32 = 0x2;
pub const buffer_usage_storage_buffer_bit: u32 = 0x20;
pub const buffer_usage_shader_device_address_bit: u32 = 0x20000;
pub const memory_property_device_local_bit: u32 = 0x1;
pub const memory_property_host_visible_bit: u32 = 0x2;
pub const memory_property_host_coherent_bit: u32 = 0x4;
pub const memory_property_host_cached_bit: u32 = 0x8;
pub const memory_allocate_device_address_bit: u32 = 0x2;
pub const shader_stage_compute_bit: u32 = 0x20;
pub const pipeline_bind_point_compute: i32 = 1;
pub const command_pool_create_reset_command_buffer_bit: u32 = 0x2;
pub const command_buffer_usage_one_time_submit_bit: u32 = 0x1;
pub const pipeline_stage_host_bit: u32 = 0x1;
pub const pipeline_stage_compute_shader_bit: u32 = 0x800;
pub const access_shader_read_bit: u32 = 0x20;
pub const access_shader_write_bit: u32 = 0x40;
pub const access_host_read_bit: u32 = 0x2000;
pub const access_host_write_bit: u32 = 0x4000;

pub const ApplicationInfo = extern struct {
    s_type: StructureType = .application_info,
    p_next: ?*const anyopaque = null,
    application_name: ?[*:0]const u8 = null,
    application_version: u32 = 0,
    engine_name: ?[*:0]const u8 = null,
    engine_version: u32 = 0,
    api_version: u32,
};

pub const InstanceCreateInfo = extern struct {
    s_type: StructureType = .instance_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    application_info: ?*const ApplicationInfo,
    enabled_layer_count: u32 = 0,
    enabled_layer_names: ?[*]const [*:0]const u8 = null,
    enabled_extension_count: u32 = 0,
    enabled_extension_names: ?[*]const [*:0]const u8 = null,
};

pub const Extent3D = extern struct { width: u32, height: u32, depth: u32 };

pub const QueueFamilyProperties = extern struct {
    queue_flags: u32,
    queue_count: u32,
    timestamp_valid_bits: u32,
    min_image_transfer_granularity: Extent3D,
};

pub const MemoryType = extern struct { property_flags: u32, heap_index: u32 };
pub const MemoryHeap = extern struct { size: u64, flags: u32 };

pub const PhysicalDeviceMemoryProperties = extern struct {
    memory_type_count: u32,
    memory_types: [32]MemoryType,
    memory_heap_count: u32,
    memory_heaps: [16]MemoryHeap,
};

pub const PhysicalDeviceLimits = extern struct {
    max_image_dimension_1d: u32,
    max_image_dimension_2d: u32,
    max_image_dimension_3d: u32,
    max_image_dimension_cube: u32,
    max_image_array_layers: u32,
    max_texel_buffer_elements: u32,
    max_uniform_buffer_range: u32,
    max_storage_buffer_range: u32,
    max_push_constants_size: u32,
    max_memory_allocation_count: u32,
    max_sampler_allocation_count: u32,
    buffer_image_granularity: u64,
    sparse_address_space_size: u64,
    max_bound_descriptor_sets: u32,
    max_per_stage_descriptor_samplers: u32,
    max_per_stage_descriptor_uniform_buffers: u32,
    max_per_stage_descriptor_storage_buffers: u32,
    max_per_stage_descriptor_sampled_images: u32,
    max_per_stage_descriptor_storage_images: u32,
    max_per_stage_descriptor_input_attachments: u32,
    max_per_stage_resources: u32,
    max_descriptor_set_samplers: u32,
    max_descriptor_set_uniform_buffers: u32,
    max_descriptor_set_uniform_buffers_dynamic: u32,
    max_descriptor_set_storage_buffers: u32,
    max_descriptor_set_storage_buffers_dynamic: u32,
    max_descriptor_set_sampled_images: u32,
    max_descriptor_set_storage_images: u32,
    max_descriptor_set_input_attachments: u32,
    max_vertex_input_attributes: u32,
    max_vertex_input_bindings: u32,
    max_vertex_input_attribute_offset: u32,
    max_vertex_input_binding_stride: u32,
    max_vertex_output_components: u32,
    max_tessellation_generation_level: u32,
    max_tessellation_patch_size: u32,
    max_tessellation_control_per_vertex_input_components: u32,
    max_tessellation_control_per_vertex_output_components: u32,
    max_tessellation_control_per_patch_output_components: u32,
    max_tessellation_control_total_output_components: u32,
    max_tessellation_evaluation_input_components: u32,
    max_tessellation_evaluation_output_components: u32,
    max_geometry_shader_invocations: u32,
    max_geometry_input_components: u32,
    max_geometry_output_components: u32,
    max_geometry_output_vertices: u32,
    max_geometry_total_output_components: u32,
    max_fragment_input_components: u32,
    max_fragment_output_attachments: u32,
    max_fragment_dual_src_attachments: u32,
    max_fragment_combined_output_resources: u32,
    max_compute_shared_memory_size: u32,
    max_compute_work_group_count: [3]u32,
    max_compute_work_group_invocations: u32,
    max_compute_work_group_size: [3]u32,
    sub_pixel_precision_bits: u32,
    sub_texel_precision_bits: u32,
    mipmap_precision_bits: u32,
    max_draw_indexed_index_value: u32,
    max_draw_indirect_count: u32,
    max_sampler_lod_bias: f32,
    max_sampler_anisotropy: f32,
    max_viewports: u32,
    max_viewport_dimensions: [2]u32,
    viewport_bounds_range: [2]f32,
    viewport_sub_pixel_bits: u32,
    min_memory_map_alignment: usize,
    min_texel_buffer_offset_alignment: u64,
    min_uniform_buffer_offset_alignment: u64,
    min_storage_buffer_offset_alignment: u64,
    min_texel_offset: i32,
    max_texel_offset: u32,
    min_texel_gather_offset: i32,
    max_texel_gather_offset: u32,
    min_interpolation_offset: f32,
    max_interpolation_offset: f32,
    sub_pixel_interpolation_offset_bits: u32,
    max_framebuffer_width: u32,
    max_framebuffer_height: u32,
    max_framebuffer_layers: u32,
    framebuffer_color_sample_counts: u32,
    framebuffer_depth_sample_counts: u32,
    framebuffer_stencil_sample_counts: u32,
    framebuffer_no_attachments_sample_counts: u32,
    max_color_attachments: u32,
    sampled_image_color_sample_counts: u32,
    sampled_image_integer_sample_counts: u32,
    sampled_image_depth_sample_counts: u32,
    sampled_image_stencil_sample_counts: u32,
    storage_image_sample_counts: u32,
    max_sample_mask_words: u32,
    timestamp_compute_and_graphics: Bool32,
    timestamp_period: f32,
    max_clip_distances: u32,
    max_cull_distances: u32,
    max_combined_clip_and_cull_distances: u32,
    discrete_queue_priorities: u32,
    point_size_range: [2]f32,
    line_width_range: [2]f32,
    point_size_granularity: f32,
    line_width_granularity: f32,
    strict_lines: Bool32,
    standard_sample_locations: Bool32,
    optimal_buffer_copy_offset_alignment: u64,
    optimal_buffer_copy_row_pitch_alignment: u64,
    non_coherent_atom_size: u64,
};

pub const PhysicalDeviceSparseProperties = extern struct {
    residency_standard_2d_block_shape: Bool32,
    residency_standard_2d_multisample_block_shape: Bool32,
    residency_standard_3d_block_shape: Bool32,
    residency_aligned_mip_size: Bool32,
    residency_non_resident_strict: Bool32,
};

pub const PhysicalDeviceProperties = extern struct {
    api_version: u32,
    driver_version: u32,
    vendor_id: u32,
    device_id: u32,
    device_type: PhysicalDeviceType,
    device_name: [256]u8,
    pipeline_cache_uuid: [16]u8,
    limits: PhysicalDeviceLimits,
    sparse_properties: PhysicalDeviceSparseProperties,
};

pub const PhysicalDeviceFeatures = extern struct {
    robust_buffer_access: Bool32 = 0,
    full_draw_index_uint32: Bool32 = 0,
    image_cube_array: Bool32 = 0,
    independent_blend: Bool32 = 0,
    geometry_shader: Bool32 = 0,
    tessellation_shader: Bool32 = 0,
    sample_rate_shading: Bool32 = 0,
    dual_src_blend: Bool32 = 0,
    logic_op: Bool32 = 0,
    multi_draw_indirect: Bool32 = 0,
    draw_indirect_first_instance: Bool32 = 0,
    depth_clamp: Bool32 = 0,
    depth_bias_clamp: Bool32 = 0,
    fill_mode_non_solid: Bool32 = 0,
    depth_bounds: Bool32 = 0,
    wide_lines: Bool32 = 0,
    large_points: Bool32 = 0,
    alpha_to_one: Bool32 = 0,
    multi_viewport: Bool32 = 0,
    sampler_anisotropy: Bool32 = 0,
    texture_compression_etc2: Bool32 = 0,
    texture_compression_astc_ldr: Bool32 = 0,
    texture_compression_bc: Bool32 = 0,
    occlusion_query_precise: Bool32 = 0,
    pipeline_statistics_query: Bool32 = 0,
    vertex_pipeline_stores_and_atomics: Bool32 = 0,
    fragment_stores_and_atomics: Bool32 = 0,
    shader_tessellation_and_geometry_point_size: Bool32 = 0,
    shader_image_gather_extended: Bool32 = 0,
    shader_storage_image_extended_formats: Bool32 = 0,
    shader_storage_image_multisample: Bool32 = 0,
    shader_storage_image_read_without_format: Bool32 = 0,
    shader_storage_image_write_without_format: Bool32 = 0,
    shader_uniform_buffer_array_dynamic_indexing: Bool32 = 0,
    shader_sampled_image_array_dynamic_indexing: Bool32 = 0,
    shader_storage_buffer_array_dynamic_indexing: Bool32 = 0,
    shader_storage_image_array_dynamic_indexing: Bool32 = 0,
    shader_clip_distance: Bool32 = 0,
    shader_cull_distance: Bool32 = 0,
    shader_float64: Bool32 = 0,
    shader_int64: Bool32 = 0,
    shader_int16: Bool32 = 0,
    shader_resource_residency: Bool32 = 0,
    shader_resource_min_lod: Bool32 = 0,
    sparse_binding: Bool32 = 0,
    sparse_residency_buffer: Bool32 = 0,
    sparse_residency_image_2d: Bool32 = 0,
    sparse_residency_image_3d: Bool32 = 0,
    sparse_residency_2_samples: Bool32 = 0,
    sparse_residency_4_samples: Bool32 = 0,
    sparse_residency_8_samples: Bool32 = 0,
    sparse_residency_16_samples: Bool32 = 0,
    sparse_residency_aliased: Bool32 = 0,
    variable_multisample_rate: Bool32 = 0,
    inherited_queries: Bool32 = 0,
};

pub const PhysicalDeviceFeatures2 = extern struct {
    s_type: StructureType = .physical_device_features_2,
    p_next: ?*anyopaque = null,
    features: PhysicalDeviceFeatures = .{},
};

pub const PhysicalDeviceBufferDeviceAddressFeatures = extern struct {
    s_type: StructureType = .physical_device_buffer_device_address_features,
    p_next: ?*anyopaque = null,
    buffer_device_address: Bool32 = 0,
    buffer_device_address_capture_replay: Bool32 = 0,
    buffer_device_address_multi_device: Bool32 = 0,
};

pub const DeviceQueueCreateInfo = extern struct {
    s_type: StructureType = .device_queue_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    queue_family_index: u32,
    queue_count: u32 = 1,
    queue_priorities: [*]const f32,
};

pub const DeviceCreateInfo = extern struct {
    s_type: StructureType = .device_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    queue_create_info_count: u32,
    queue_create_infos: [*]const DeviceQueueCreateInfo,
    enabled_layer_count: u32 = 0,
    enabled_layer_names: ?[*]const [*:0]const u8 = null,
    enabled_extension_count: u32 = 0,
    enabled_extension_names: ?[*]const [*:0]const u8 = null,
    enabled_features: ?*const PhysicalDeviceFeatures,
};

pub const BufferCreateInfo = extern struct {
    s_type: StructureType = .buffer_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    size: u64,
    usage: u32,
    sharing_mode: i32 = 0,
    queue_family_index_count: u32 = 0,
    queue_family_indices: ?[*]const u32 = null,
};

pub const MemoryRequirements = extern struct { size: u64, alignment: u64, memory_type_bits: u32 };

pub const MemoryAllocateFlagsInfo = extern struct {
    s_type: StructureType = .memory_allocate_flags_info,
    p_next: ?*const anyopaque = null,
    flags: u32,
    device_mask: u32 = 0,
};

pub const MemoryAllocateInfo = extern struct {
    s_type: StructureType = .memory_allocate_info,
    p_next: ?*const anyopaque = null,
    allocation_size: u64,
    memory_type_index: u32,
};

pub const BufferDeviceAddressInfo = extern struct {
    s_type: StructureType = .buffer_device_address_info,
    p_next: ?*const anyopaque = null,
    buffer: Handle,
};

pub const ShaderModuleCreateInfo = extern struct {
    s_type: StructureType = .shader_module_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    code_size: usize,
    code: [*]const u32,
};

pub const PushConstantRange = extern struct { stage_flags: u32, offset: u32, size: u32 };

pub const PipelineLayoutCreateInfo = extern struct {
    s_type: StructureType = .pipeline_layout_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    set_layout_count: u32 = 0,
    set_layouts: ?[*]const Handle = null,
    push_constant_range_count: u32,
    push_constant_ranges: [*]const PushConstantRange,
};

pub const PipelineShaderStageCreateInfo = extern struct {
    s_type: StructureType = .pipeline_shader_stage_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    stage: u32,
    module: Handle,
    name: [*:0]const u8,
    specialization_info: ?*const anyopaque = null,
};

pub const ComputePipelineCreateInfo = extern struct {
    s_type: StructureType = .compute_pipeline_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    stage: PipelineShaderStageCreateInfo,
    layout: Handle,
    base_pipeline_handle: Handle = .null,
    base_pipeline_index: i32 = -1,
};

pub const CommandPoolCreateInfo = extern struct {
    s_type: StructureType = .command_pool_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32,
    queue_family_index: u32,
};

pub const CommandBufferAllocateInfo = extern struct {
    s_type: StructureType = .command_buffer_allocate_info,
    p_next: ?*const anyopaque = null,
    command_pool: Handle,
    level: i32 = 0,
    command_buffer_count: u32 = 1,
};

pub const CommandBufferBeginInfo = extern struct {
    s_type: StructureType = .command_buffer_begin_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    inheritance_info: ?*const anyopaque = null,
};

pub const MemoryBarrier = extern struct {
    s_type: StructureType = .memory_barrier,
    p_next: ?*const anyopaque = null,
    src_access_mask: u32,
    dst_access_mask: u32,
};

pub const SubmitInfo = extern struct {
    s_type: StructureType = .submit_info,
    p_next: ?*const anyopaque = null,
    wait_semaphore_count: u32 = 0,
    wait_semaphores: ?[*]const Handle = null,
    wait_dst_stage_mask: ?[*]const u32 = null,
    command_buffer_count: u32,
    command_buffers: [*]const CommandBuffer,
    signal_semaphore_count: u32 = 0,
    signal_semaphores: ?[*]const Handle = null,
};

pub const FenceCreateInfo = extern struct {
    s_type: StructureType = .fence_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
};

pub const AllocationCallbacks = opaque {};
pub const VoidFunction = *const fn () callconv(.c) void;
pub const GetInstanceProcAddr = *const fn (?Instance, [*:0]const u8) callconv(.c) ?VoidFunction;

/// Entry points resolved through `vkGetInstanceProcAddr`; field names are the Vulkan names
/// without the `vk` prefix, in snake case.
pub const Functions = struct {
    get_instance_proc_addr: GetInstanceProcAddr,
    create_instance: *const fn (*const InstanceCreateInfo, ?*const AllocationCallbacks, *?Instance) callconv(.c) Result = undefined,
    destroy_instance: *const fn (Instance, ?*const AllocationCallbacks) callconv(.c) void = undefined,
    enumerate_physical_devices: *const fn (Instance, *u32, ?[*]PhysicalDevice) callconv(.c) Result = undefined,
    get_physical_device_properties: *const fn (PhysicalDevice, *PhysicalDeviceProperties) callconv(.c) void = undefined,
    get_physical_device_features2: *const fn (PhysicalDevice, *PhysicalDeviceFeatures2) callconv(.c) void = undefined,
    get_physical_device_queue_family_properties: *const fn (PhysicalDevice, *u32, ?[*]QueueFamilyProperties) callconv(.c) void = undefined,
    get_physical_device_memory_properties: *const fn (PhysicalDevice, *PhysicalDeviceMemoryProperties) callconv(.c) void = undefined,
    create_device: *const fn (PhysicalDevice, *const DeviceCreateInfo, ?*const AllocationCallbacks, *?Device) callconv(.c) Result = undefined,
    destroy_device: *const fn (Device, ?*const AllocationCallbacks) callconv(.c) void = undefined,
    get_device_queue: *const fn (Device, u32, u32, *?Queue) callconv(.c) void = undefined,
    create_buffer: *const fn (Device, *const BufferCreateInfo, ?*const AllocationCallbacks, *Handle) callconv(.c) Result = undefined,
    destroy_buffer: *const fn (Device, Handle, ?*const AllocationCallbacks) callconv(.c) void = undefined,
    get_buffer_memory_requirements: *const fn (Device, Handle, *MemoryRequirements) callconv(.c) void = undefined,
    allocate_memory: *const fn (Device, *const MemoryAllocateInfo, ?*const AllocationCallbacks, *Handle) callconv(.c) Result = undefined,
    free_memory: *const fn (Device, Handle, ?*const AllocationCallbacks) callconv(.c) void = undefined,
    bind_buffer_memory: *const fn (Device, Handle, Handle, u64) callconv(.c) Result = undefined,
    map_memory: *const fn (Device, Handle, u64, u64, u32, *?*anyopaque) callconv(.c) Result = undefined,
    get_buffer_device_address: *const fn (Device, *const BufferDeviceAddressInfo) callconv(.c) u64 = undefined,
    create_shader_module: *const fn (Device, *const ShaderModuleCreateInfo, ?*const AllocationCallbacks, *Handle) callconv(.c) Result = undefined,
    destroy_shader_module: *const fn (Device, Handle, ?*const AllocationCallbacks) callconv(.c) void = undefined,
    create_pipeline_layout: *const fn (Device, *const PipelineLayoutCreateInfo, ?*const AllocationCallbacks, *Handle) callconv(.c) Result = undefined,
    destroy_pipeline_layout: *const fn (Device, Handle, ?*const AllocationCallbacks) callconv(.c) void = undefined,
    create_compute_pipelines: *const fn (Device, Handle, u32, [*]const ComputePipelineCreateInfo, ?*const AllocationCallbacks, [*]Handle) callconv(.c) Result = undefined,
    destroy_pipeline: *const fn (Device, Handle, ?*const AllocationCallbacks) callconv(.c) void = undefined,
    create_command_pool: *const fn (Device, *const CommandPoolCreateInfo, ?*const AllocationCallbacks, *Handle) callconv(.c) Result = undefined,
    destroy_command_pool: *const fn (Device, Handle, ?*const AllocationCallbacks) callconv(.c) void = undefined,
    allocate_command_buffers: *const fn (Device, *const CommandBufferAllocateInfo, [*]?CommandBuffer) callconv(.c) Result = undefined,
    reset_command_buffer: *const fn (CommandBuffer, u32) callconv(.c) Result = undefined,
    begin_command_buffer: *const fn (CommandBuffer, *const CommandBufferBeginInfo) callconv(.c) Result = undefined,
    end_command_buffer: *const fn (CommandBuffer) callconv(.c) Result = undefined,
    cmd_bind_pipeline: *const fn (CommandBuffer, i32, Handle) callconv(.c) void = undefined,
    cmd_push_constants: *const fn (CommandBuffer, Handle, u32, u32, u32, *const anyopaque) callconv(.c) void = undefined,
    cmd_dispatch: *const fn (CommandBuffer, u32, u32, u32) callconv(.c) void = undefined,
    cmd_pipeline_barrier: *const fn (CommandBuffer, u32, u32, u32, u32, ?[*]const MemoryBarrier, u32, ?*const anyopaque, u32, ?*const anyopaque) callconv(.c) void = undefined,
    queue_submit: *const fn (Queue, u32, [*]const SubmitInfo, Handle) callconv(.c) Result = undefined,
    create_fence: *const fn (Device, *const FenceCreateInfo, ?*const AllocationCallbacks, *Handle) callconv(.c) Result = undefined,
    destroy_fence: *const fn (Device, Handle, ?*const AllocationCallbacks) callconv(.c) void = undefined,
    wait_for_fences: *const fn (Device, u32, [*]const Handle, Bool32, u64) callconv(.c) Result = undefined,
    reset_fences: *const fn (Device, u32, [*]const Handle) callconv(.c) Result = undefined,
    device_wait_idle: *const fn (Device) callconv(.c) Result = undefined,

    /// Resolves every entry point except `create_instance`, which needs no instance.
    pub fn loadInstance(self: *Functions, instance: Instance) error{MissingVulkanFunction}!void {
        @setEvalBranchQuota(20_000);
        inline for (@typeInfo(Functions).@"struct".field_names) |field_name| {
            if (comptime std.mem.eql(u8, field_name, "get_instance_proc_addr") or std.mem.eql(u8, field_name, "create_instance")) continue;
            @field(self, field_name) = @ptrCast(self.get_instance_proc_addr(instance, comptime vkName(field_name)) orelse return error.MissingVulkanFunction);
        }
    }

    pub fn loadGlobal(self: *Functions) error{MissingVulkanFunction}!void {
        self.create_instance = @ptrCast(self.get_instance_proc_addr(null, "vkCreateInstance") orelse return error.MissingVulkanFunction);
    }

    /// `get_physical_device_features2` -> "vkGetPhysicalDeviceFeatures2".
    fn vkName(comptime snake: []const u8) [:0]const u8 {
        comptime {
            var out: [snake.len + 2:0]u8 = undefined;
            var n: usize = 0;
            out[n] = 'v';
            n += 1;
            out[n] = 'k';
            n += 1;
            var upper = true;
            for (snake) |ch| {
                if (ch == '_') {
                    upper = true;
                    continue;
                }
                out[n] = if (upper) std.ascii.toUpper(ch) else ch;
                upper = false;
                n += 1;
            }
            out[n] = 0;
            const final = out[0..n :0].*;
            return &final;
        }
    }
};

comptime {
    // Layout guards for the structs most likely to be mis-declared.
    std.debug.assert(@sizeOf(PhysicalDeviceLimits) == 504);
    std.debug.assert(@sizeOf(PhysicalDeviceProperties) == 824);
    std.debug.assert(@sizeOf(PhysicalDeviceFeatures) == 220);
    std.debug.assert(@sizeOf(PhysicalDeviceMemoryProperties) == 520);
}

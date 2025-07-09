const std = @import("std");
const builtin = @import("builtin");

const featureDistributionMatch = @import("zignal").featureDistributionMatch;
const Image = @import("zignal").Image;
const loadPng = @import("zignal").loadPng;
const Rgba = @import("zignal").Rgba;
const savePng = @import("zignal").savePng;

pub const std_options: std.Options = .{
    .logFn = if (builtin.cpu.arch.isWasm()) @import("js.zig").logFn else std.log.defaultLog,
    .log_level = std.log.default_level,
};

pub fn panic(msg: []const u8, st: ?*std.builtin.StackTrace, addr: ?usize) noreturn {
    _ = st;
    _ = addr;
    std.log.err("panic: {s}", .{msg});
    @trap();
}

/// Apply Feature Distribution Matching between source and reference images
pub export fn fdm(
    src_ptr: [*]Rgba,
    src_rows: usize,
    src_cols: usize,
    ref_ptr: [*]Rgba,
    ref_rows: usize,
    ref_cols: usize,
    extra_ptr: ?[*]u8,
    extra_len: usize,
) void {
    const allocator: std.mem.Allocator = blk: {
        if (builtin.cpu.arch.isWasm() and builtin.os.tag == .freestanding) {
            const min_size = (src_rows * src_cols + ref_rows * ref_cols) * @sizeOf(f64) * 50;
            if (extra_len < min_size) {
                std.log.err("Not enough extra memory: need at least {d}, got {d}", .{ min_size, extra_len });
                @panic("Insufficient memory for FDM");
            }
            if (extra_ptr) |ptr| {
                var fba = std.heap.FixedBufferAllocator.init(ptr[0..extra_len]);
                break :blk fba.allocator();
            } else {
                @panic("ERROR: extra_ptr can't be null when running in WebAssembly.");
            }
        } else {
            break :blk std.heap.page_allocator;
        }
    };

    const src_size = src_rows * src_cols;
    const ref_size = ref_rows * ref_cols;

    const src_img: Image(Rgba) = .init(src_rows, src_cols, src_ptr[0..src_size]);
    const ref_img: Image(Rgba) = .init(ref_rows, ref_cols, ref_ptr[0..ref_size]);

    // Apply FDM
    featureDistributionMatch(Rgba, allocator, src_img, ref_img) catch |err| {
        std.log.err("FDM failed: {}", .{err});
        @panic("FDM failed");
    };
}

// pub fn main() !void {
//     var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
//     defer _ = debug_allocator.deinit();
//     const gpa = debug_allocator.allocator();
//     var args = std.process.args();
//     _ = args.next(); // Skip program name
//     const src_path = args.next() orelse @panic("provide src image");
//     const ref_path = args.next() orelse @panic("provide ref image");
//     var src_img = try loadPng(Rgba, gpa, src_path);
//     defer src_img.deinit(gpa);
//     var ref_img = try loadPng(Rgba, gpa, ref_path);
//     defer ref_img.deinit(gpa);
//     var timer = try std.time.Timer.start();
//     const t0 = timer.read();
//     try featureDistributionMatch(Rgba, gpa, src_img, ref_img);
//     const t1 = timer.read();
//     std.debug.print("src size: {d}x{d}\n", .{ src_img.cols, src_img.rows });
//     std.debug.print("ref size: {d}x{d}\n", .{ ref_img.cols, ref_img.rows });
//     std.debug.print("FDM: {d:.3} ms\n", .{@as(f32, @floatFromInt(t1 - t0)) / std.time.ns_per_ms});
//     try savePng(Rgba, gpa, src_img, "fdm.png");
// }

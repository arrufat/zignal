const std = @import("std");
const builtin = @import("builtin");

const FeatureDistributionMatching = @import("zignal").FeatureDistributionMatching;
const Image = @import("zignal").Image;
const loadPng = @import("zignal").loadPng;
const Rgba = @import("zignal").Rgba(u8);
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

/// Apply Feature Distribution Matching between source and target images
pub export fn fdm(
    source_ptr: [*]Rgba,
    source_rows: usize,
    source_cols: usize,
    target_ptr: [*]Rgba,
    target_rows: usize,
    target_cols: usize,
    extra_ptr: ?[*]u8,
    extra_len: usize,
) void {
    const allocator: std.mem.Allocator = blk: {
        if (builtin.cpu.arch.isWasm() and builtin.os.tag == .freestanding) {
            const min_size = (source_rows * source_cols + target_rows * target_cols) * @sizeOf(f64) * 50;
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

    const src_size = source_rows * source_cols;
    const ref_size = target_rows * target_cols;

    const src_img: Image(Rgba) = .initFromSlice(source_rows, source_cols, source_ptr[0..src_size]);
    const ref_img: Image(Rgba) = .initFromSlice(target_rows, target_cols, target_ptr[0..ref_size]);

    // Apply FDM using new API
    var matcher = FeatureDistributionMatching(Rgba).init(allocator);
    defer matcher.deinit();

    matcher.match(src_img, ref_img) catch |err| {
        std.log.err("FDM match failed: {}", .{err});
        @panic("FDM match failed");
    };
}

const std = @import("std");
const builtin = @import("builtin");

const FeatureDistributionMatching = @import("zignal").FeatureDistributionMatching;
const Image = @import("zignal").Image;

const Rgba = @import("zignal").Rgba(u8);

const js = @import("js.zig");

pub const std_options: std.Options = .{
    .logFn = if (builtin.cpu.arch.isWasm()) js.logFn else std.log.defaultLog,
    .log_level = std.log.default_level,
};

comptime {
    _ = js.alloc;
    _ = js.free;
}

pub fn panic(msg: []const u8, st: ?*std.builtin.StackTrace, addr: ?usize) noreturn {
    _ = st;
    _ = addr;
    std.log.err("panic: {s}", .{msg});
    @trap();
}

/// Apply Feature Distribution Matching between source and target images
pub export fn fdm(
    source_ptr: [*]Rgba,
    source_rows: u32,
    source_cols: u32,
    target_ptr: [*]Rgba,
    target_rows: u32,
    target_cols: u32,
    extra_ptr: ?[*]u8,
    extra_len: usize,
) void {
    const source_size = @as(usize, source_rows) * @as(usize, source_cols);
    const target_size = @as(usize, target_rows) * @as(usize, target_cols);
    const allocator: std.mem.Allocator = blk: {
        if (builtin.cpu.arch.isWasm() and builtin.os.tag == .freestanding) {
            const min_size = (source_size + target_size) * @sizeOf(f64) * 50;
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

    const source_image: Image(Rgba) = .initFromSlice(source_rows, source_cols, source_ptr[0..source_size]);
    const target_image: Image(Rgba) = .initFromSlice(target_rows, target_cols, target_ptr[0..target_size]);

    var matcher: FeatureDistributionMatching(Rgba) = .init(allocator);
    defer matcher.deinit();

    matcher.match(source_image, target_image) catch |err| {
        std.log.err("FDM match failed: {}", .{err});
        @panic("FDM match failed");
    };
}

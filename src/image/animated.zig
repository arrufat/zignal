//! Generic container for animated raster images.
//!
//! Used today by GIF and designed to be reused for future animated formats
//! (APNG, animated WebP). Frames are fully composed (post-disposal) — callers
//! iterate frames without needing format-specific knowledge.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Image = @import("../image.zig").Image;

/// Animated image with N frames, per-frame display delays, and a loop count.
/// Each frame owns its pixel buffer; `deinit` walks them all.
pub fn AnimatedImage(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Fully-composed frames in display order.
        frames: []Image(T),
        /// Per-frame display delay in centiseconds (1 cs = 10 ms). `len == frames.len`.
        delays_cs: []u16,
        /// Loop count: 0 = infinite, N>0 = play N times.
        loop_count: u16,

        pub fn deinit(self: *Self, gpa: Allocator) void {
            for (self.frames) |*f| f.deinit(gpa);
            gpa.free(self.frames);
            gpa.free(self.delays_cs);
            self.frames = &.{};
            self.delays_cs = &.{};
        }

        pub inline fn frameCount(self: Self) usize {
            return self.frames.len;
        }

        pub inline fn frame(self: Self, i: usize) Image(T) {
            return self.frames[i];
        }

        /// Total wall-clock duration in milliseconds (sum of per-frame delays).
        pub fn totalDurationMs(self: Self) u64 {
            var sum: u64 = 0;
            for (self.delays_cs) |cs| sum += @as(u64, cs) * 10;
            return sum;
        }
    };
}

test "AnimatedImage(u8) — build, deinit, helpers" {
    const gpa = std.testing.allocator;

    var frames = try gpa.alloc(Image(u8), 2);
    frames[0] = try Image(u8).init(gpa, 4, 4);
    @memset(frames[0].data, 0x10);
    frames[1] = try Image(u8).init(gpa, 4, 4);
    @memset(frames[1].data, 0x20);

    var delays = try gpa.alloc(u16, 2);
    delays[0] = 10; // 100 ms
    delays[1] = 25; // 250 ms

    var anim = AnimatedImage(u8){
        .frames = frames,
        .delays_cs = delays,
        .loop_count = 0,
    };
    defer anim.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), anim.frameCount());
    try std.testing.expectEqual(@as(u8, 0x10), anim.frame(0).at(0, 0).*);
    try std.testing.expectEqual(@as(u8, 0x20), anim.frame(1).at(0, 0).*);
    try std.testing.expectEqual(@as(u64, 350), anim.totalDurationMs());
    try std.testing.expectEqual(@as(u16, 0), anim.loop_count);
}

//! Generic container for animated raster images, loaded from GIF, WebP or JPEG XL (and any
//! still format as a single frame). Frames are fully composed (post-disposal), so callers
//! iterate frames without format-specific knowledge.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const codecs = @import("../codecs.zig");
const Image = @import("../image.zig").Image;
const ImageFormat = @import("format.zig").ImageFormat;

/// Animated image with N frames, per-frame display durations, and a loop count.
/// Each frame owns its pixel buffer; `deinit` walks them all.
pub fn AnimatedImage(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Fully-composed frames in display order.
        frames: []Image(T),
        /// Per-frame display duration in milliseconds. `len == frames.len`.
        durations_ms: []u32,
        /// Loop count: 0 = infinite, N>0 = play N times.
        loop_count: u32,

        /// Loads every frame of `file_path`, detecting the format from its signature.
        /// Still formats give one frame with a zero duration.
        pub fn load(io: Io, allocator: Allocator, file_path: []const u8) !Self {
            const data = try codecs.readFile(io, allocator, file_path, codecs.max_file_size);
            defer allocator.free(data);
            return loadFromBytes(io, allocator, data);
        }

        /// `load` for an in-memory encoded image.
        pub fn loadFromBytes(io: Io, allocator: Allocator, data: []const u8) !Self {
            const format = ImageFormat.detectFromBytes(data) orelse return error.UnsupportedImageFormat;
            switch (format) {
                inline else => |f| {
                    const codec = @field(codecs, @tagName(f));
                    if (@hasDecl(codec, "loadAnimatedFromBytes")) return codec.loadAnimatedFromBytes(T, io, allocator, data, .{});
                    return fromStill(allocator, try codec.loadFromBytes(T, io, allocator, data, .{}));
                },
            }
        }

        /// Saves by extension. Codecs with `encodeAnimated` (GIF, JPEG XL) store every frame; any other
        /// format takes a single frame.
        pub fn save(self: Self, io: Io, allocator: Allocator, file_path: []const u8) !void {
            const format = ImageFormat.fromExtension(file_path) orelse return error.UnsupportedImageFormat;
            switch (format) {
                inline else => |f| {
                    const codec = @field(codecs, @tagName(f));
                    if (@hasDecl(codec, "encodeAnimated")) {
                        const bytes = try codec.encodeAnimated(T, io, allocator, self, .default);
                        defer allocator.free(bytes);
                        return codecs.writeFile(io, file_path, bytes);
                    }
                    if (self.frames.len != 1) return error.UnsupportedAnimation;
                    return codec.save(T, io, allocator, self.frames[0], file_path);
                },
            }
        }

        /// Wraps an owned still image as a one-frame animation; frees it on failure.
        pub fn fromStill(allocator: Allocator, image: Image(T)) !Self {
            var still = image;
            errdefer still.deinit(allocator);
            const frames = try allocator.alloc(Image(T), 1);
            errdefer allocator.free(frames);
            const durations = try allocator.alloc(u32, 1);
            frames[0] = still;
            durations[0] = 0;
            return .{ .frames = frames, .durations_ms = durations, .loop_count = 0 };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            for (self.frames) |*f| f.deinit(allocator);
            allocator.free(self.frames);
            allocator.free(self.durations_ms);
            self.frames = &.{};
            self.durations_ms = &.{};
        }

        pub inline fn frameCount(self: Self) usize {
            return self.frames.len;
        }

        pub inline fn frame(self: Self, i: usize) Image(T) {
            return self.frames[i];
        }

        /// Checks the invariants encoders rely on: at least one frame, one duration per frame
        /// and every frame the size of the first.
        pub fn validate(self: Self) !void {
            if (self.frames.len == 0) return error.NoFrames;
            if (self.frames.len != self.durations_ms.len) return error.InconsistentDurations;
            for (self.frames[1..]) |f| {
                if (!f.hasSameShape(self.frames[0])) return error.InconsistentFrameDimensions;
            }
        }

        /// Total wall-clock duration in milliseconds.
        pub fn totalDurationMs(self: Self) u64 {
            var sum: u64 = 0;
            for (self.durations_ms) |ms| sum += ms;
            return sum;
        }
    };
}

/// Collects decoded frames for a codec's `loadAnimatedFromBytes`, owning them until
/// `finish` hands them over.
pub fn Builder(comptime T: type) type {
    return struct {
        const Self = @This();

        frames: std.ArrayList(Image(T)) = .empty,
        durations_ms: std.ArrayList(u32) = .empty,

        pub fn append(self: *Self, allocator: Allocator, image: Image(T), duration_ms: u32) !void {
            var owned = image;
            errdefer owned.deinit(allocator);
            try self.frames.ensureUnusedCapacity(allocator, 1);
            try self.durations_ms.append(allocator, duration_ms);
            self.frames.appendAssumeCapacity(owned);
        }

        pub fn finish(self: *Self, allocator: Allocator, loop_count: u32) !AnimatedImage(T) {
            if (self.frames.items.len == 0) return error.NoFrames;
            const frames = try self.frames.toOwnedSlice(allocator);
            errdefer allocator.free(frames);
            return .{
                .frames = frames,
                .durations_ms = try self.durations_ms.toOwnedSlice(allocator),
                .loop_count = loop_count,
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            for (self.frames.items) |*f| f.deinit(allocator);
            self.frames.deinit(allocator);
            self.durations_ms.deinit(allocator);
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

    var durations = try gpa.alloc(u32, 2);
    durations[0] = 100;
    durations[1] = 250;

    var anim = AnimatedImage(u8){
        .frames = frames,
        .durations_ms = durations,
        .loop_count = 0,
    };
    defer anim.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), anim.frameCount());
    try std.testing.expectEqual(@as(u8, 0x10), anim.frame(0).at(0, 0).*);
    try std.testing.expectEqual(@as(u8, 0x20), anim.frame(1).at(0, 0).*);
    try std.testing.expectEqual(@as(u64, 350), anim.totalDurationMs());
    try std.testing.expectEqual(@as(u32, 0), anim.loop_count);
}

test "still formats load as one frame" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var img: Image(u8) = try .init(gpa, 3, 5);
    defer img.deinit(gpa);
    @memset(img.data, 0x42);
    const png = try codecs.png.encode(u8, io, gpa, img, .default);
    defer gpa.free(png);

    var anim: AnimatedImage(u8) = try .loadFromBytes(io, gpa, png);
    defer anim.deinit(gpa);
    try std.testing.expectEqual(1, anim.frameCount());
    try std.testing.expectEqual(0, anim.durations_ms[0]);
    try std.testing.expectEqualSlices(u8, img.data, anim.frame(0).data);
}

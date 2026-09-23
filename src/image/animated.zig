//! Generic container for animated raster images, loaded from GIF, WebP or JPEG XL (and any
//! still format as a single frame). Frames are fully composed (post-disposal), so callers
//! iterate frames without format-specific knowledge.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const codecs = @import("../codecs.zig");
const Image = @import("../image.zig").Image;
const Rectangle = @import("../geometry.zig").Rectangle;
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
            return codecs.readFile(io, file_path, read, .{ io, allocator }, .{});
        }

        /// Reads every frame from `reader`, detecting the format from its signature.
        pub fn read(io: Io, allocator: Allocator, reader: *Io.Reader) !Self {
            switch (try ImageFormat.peek(reader)) {
                inline else => |f| {
                    const codec = @field(codecs, @tagName(f));
                    if (@hasDecl(codec, "readAnimated")) return codec.readAnimated(T, io, allocator, reader, .{});
                    return fromStill(allocator, try codec.read(T, io, allocator, reader, .{}));
                },
            }
        }

        /// `load` for an in-memory encoded image.
        pub fn loadFromBytes(io: Io, allocator: Allocator, data: []const u8) !Self {
            const format = ImageFormat.detectFromBytes(data) orelse return error.UnsupportedImageFormat;
            switch (format) {
                inline else => |f| {
                    const codec = @field(codecs, @tagName(f));
                    return if (@hasDecl(codec, "loadAnimatedFromBytes"))
                        codec.loadAnimatedFromBytes(T, io, allocator, data, .{})
                    else
                        fromStill(allocator, try codec.loadFromBytes(T, io, allocator, data, .{}));
                },
            }
        }

        /// Saves by extension. Codecs with `writeAnimated` store every frame; any other
        /// format takes a single frame.
        pub fn save(self: Self, io: Io, allocator: Allocator, file_path: []const u8) !void {
            const format = ImageFormat.fromExtension(file_path) orelse return error.UnsupportedImageFormat;
            // Checked before the file is created.
            const animated = switch (format) {
                inline else => |f| @hasDecl(@field(codecs, @tagName(f)), "writeAnimated"),
            };
            if (!animated and self.frames.len != 1) return error.UnsupportedAnimation;
            return codecs.writeFile(io, file_path, write, .{ self, io, allocator }, .{format});
        }

        /// Writes every frame to `writer` as `format`; still formats take a single frame.
        pub fn write(self: Self, io: Io, allocator: Allocator, writer: *Io.Writer, format: ImageFormat) !void {
            switch (format) {
                inline else => |f| {
                    const codec = @field(codecs, @tagName(f));
                    if (@hasDecl(codec, "writeAnimated")) return codec.writeAnimated(T, io, allocator, writer, self, .default);
                    if (self.frames.len != 1) return error.UnsupportedAnimation;
                    return codec.write(T, io, allocator, writer, self.frames[0], .default);
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

        /// The region of frame `i` that differs from frame `i - 1`. An identical frame keeps one
        /// pixel so its duration survives.
        pub fn changedRegion(self: Self, i: usize) Rectangle(u32) {
            if (i == 0) return self.frames[0].getRectangle();
            return self.frames[i].diffBounds(self.frames[i - 1]) orelse .init(0, 0, 1, 1);
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

test "save writes what encode returns" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);

    var anim: AnimatedImage(u8) = try .fromStill(gpa, try .init(gpa, 6, 9));
    defer anim.deinit(gpa);
    for (anim.frame(0).data, 0..) |*p, i| p.* = @truncate(i * 7);

    inline for (.{ "png", "bmp", "gif", "jpg" }, .{ codecs.png, codecs.bmp, codecs.gif, codecs.jpeg }) |ext, codec| {
        const path = try std.fs.path.join(gpa, &.{ dir, "still." ++ ext });
        defer gpa.free(path);
        try anim.frame(0).save(io, gpa, path);
        const saved = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        defer gpa.free(saved);
        const encoded = try codec.encode(u8, io, gpa, anim.frame(0), .default);
        defer gpa.free(encoded);
        try std.testing.expectEqualSlices(u8, encoded, saved);

        try anim.save(io, gpa, path);
        const saved_anim = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        defer gpa.free(saved_anim);
        const encoded_anim = if (@hasDecl(codec, "encodeAnimated")) try codec.encodeAnimated(u8, io, gpa, anim, .default) else try codec.encode(u8, io, gpa, anim.frame(0), .default);
        defer gpa.free(encoded_anim);
        try std.testing.expectEqualSlices(u8, encoded_anim, saved_anim);
    }
}

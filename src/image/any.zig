//! Images whose pixel type is picked at runtime.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const codecs = @import("../codecs.zig");
const Format = @import("format.zig").Format;
const Image = @import("../image.zig").Image;
const Rgb = @import("../color.zig").Rgb(u8);
const Rgba = @import("../color.zig").Rgba(u8);

/// An image in any of the common pixel types. Codecs decode into the one closest to how
/// the file stores it; `into` converts to the type the caller wants.
pub const Any = union(enum) {
    grayscale: Image(u8),
    rgb: Image(Rgb),
    rgba: Image(Rgba),

    /// Decode limits for each codec `load`, `read` and `loadFromBytes` may dispatch to.
    pub const Limits = struct {
        png: codecs.png.DecodeLimits = .default,
        jpeg: codecs.jpeg.DecodeLimits = .default,
        bmp: codecs.bmp.DecodeLimits = .default,
        gif: codecs.gif.DecodeLimits = .default,
        jxl: codecs.jxl.DecodeLimits = .default,
        webp: codecs.webp.DecodeLimits = .default,

        pub const default: Limits = .{};
    };

    /// Loads `file_path`, detecting the format from its signature.
    pub fn load(io: Io, allocator: Allocator, file_path: []const u8, limits: Limits) !Any {
        return codecs.readFile(io, file_path, read, .{ io, allocator }, .{limits});
    }

    /// Reads an image from `reader`, detecting the format from its signature.
    pub fn read(io: Io, allocator: Allocator, reader: *Io.Reader, limits: Limits) !Any {
        return switch (try Format.peek(reader)) {
            inline else => |f| @field(codecs, @tagName(f)).readAny(io, allocator, reader, @field(limits, @tagName(f))),
        };
    }

    /// Loads an image from an in-memory byte buffer, detecting the format from its signature.
    pub fn loadFromBytes(io: Io, allocator: Allocator, data: []const u8, limits: Limits) !Any {
        const format = Format.detectFromBytes(data) orelse return error.UnsupportedImageFormat;
        return switch (format) {
            inline else => |f| @field(codecs, @tagName(f)).loadAnyFromBytes(io, allocator, data, @field(limits, @tagName(f))),
        };
    }

    pub fn deinit(self: *Any, allocator: Allocator) void {
        switch (self.*) {
            inline else => |*img| img.deinit(allocator),
        }
    }

    /// Hands over the image as `Image(T)`, converting (and freeing the original) only when
    /// the pixel types differ.
    pub fn into(self: *Any, comptime T: type, io: Io, allocator: Allocator) !Image(T) {
        switch (self.*) {
            inline else => |*img| {
                if (@TypeOf(img.*) == Image(T)) return img.*;
                defer self.deinit(allocator);
                return img.convert(io, allocator, T);
            },
        }
    }
};

test "loaders keep the file's pixel type" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var gray: Image(u8) = try .init(gpa, 2, 3);
    defer gray.deinit(gpa);
    for (gray.data, 0..) |*p, i| p.* = @intCast(i * 40);
    const png_bytes = try codecs.png.encode(u8, io, gpa, gray, .default);
    defer gpa.free(png_bytes);

    var from_bytes: Any = try .loadFromBytes(io, gpa, png_bytes, .default);
    defer from_bytes.deinit(gpa);
    try std.testing.expectEqualSlices(u8, gray.data, from_bytes.grayscale.data);

    var reader: Io.Reader = .fixed(png_bytes);
    var from_reader: Any = try .read(io, gpa, &reader, .default);
    defer from_reader.deinit(gpa);
    try std.testing.expectEqualSlices(u8, gray.data, from_reader.grayscale.data);

    var rgb: Image(Rgb) = try .init(gpa, 2, 2);
    defer rgb.deinit(gpa);
    @memset(rgb.data, .{ .r = 10, .g = 20, .b = 30 });
    const bmp_bytes = try codecs.bmp.encode(Rgb, io, gpa, rgb, .default);
    defer gpa.free(bmp_bytes);

    var from_bmp: Any = try .loadFromBytes(io, gpa, bmp_bytes, .default);
    defer from_bmp.deinit(gpa);
    try std.testing.expectEqualSlices(Rgb, rgb.data, from_bmp.rgb.data);

    try std.testing.expectError(error.UnsupportedImageFormat, Any.loadFromBytes(io, gpa, "not an image", .default));
}

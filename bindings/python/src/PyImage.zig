const std = @import("std");

const zignal = @import("zignal");
const Image = zignal.Image;
const Rgb = zignal.Rgb;
const Rgba = zignal.Rgba;

/// PyImage is a Python-facing dynamic image wrapper used only by the Python bindings.
/// Internally it stores one of Image(u8), Image(Rgb), or Image(Rgba) and centralizes
/// format dispatch behind a single type. Start with RGBA-only; add Gray/RGB incrementally.
pub const PyImage = struct {
    /// Data type enum with u8 backing for extern compatibility
    pub const DType = enum(u8) { grayscale, rgb, rgba };

    pub const Variant = union(DType) {
        grayscale: Image(u8),
        rgb: Image(Rgb),
        rgba: Image(Rgba),
    };

    pub const Ownership = enum { owned, borrowed };
    data: Variant,
    ownership: Ownership = .owned,

    pub fn initRgba(image: Image(Rgba)) PyImage {
        return .{ .data = .{ .rgba = image } };
    }

    pub fn deinit(self: *PyImage, allocator: std.mem.Allocator) void {
        if (self.ownership == .owned) {
            switch (self.data) {
                inline else => |*img| img.deinit(allocator),
            }
        }
    }

    /// Factory: allocate a PyImage from a concrete Image(T).
    /// Use Ownership.borrowed for views to avoid double-free.
    pub fn createFrom(allocator: std.mem.Allocator, image: anytype, ownership: Ownership) ?*PyImage {
        const p = allocator.create(PyImage) catch return null;
        switch (@TypeOf(image)) {
            Image(u8) => p.* = .{ .data = .{ .grayscale = image }, .ownership = ownership },
            Image(Rgb) => p.* = .{ .data = .{ .rgb = image }, .ownership = ownership },
            Image(Rgba) => p.* = .{ .data = .{ .rgba = image }, .ownership = ownership },
            else => {
                allocator.destroy(p);
                return null;
            },
        }
        return p;
    }

    pub fn rows(self: *const PyImage) usize {
        return switch (self.data) {
            inline else => |img| img.rows,
        };
    }

    pub fn cols(self: *const PyImage) usize {
        return switch (self.data) {
            inline else => |img| img.cols,
        };
    }

    /// Return the pixel as Rgba regardless of underlying storage, for uniform Python API.
    pub fn getPixelRgba(self: *const PyImage, row: usize, col: usize) Rgba {
        return switch (self.data) {
            .grayscale => |img| blk: {
                const v = img.at(row, col).*;
                break :blk Rgba{ .r = v, .g = v, .b = v, .a = 255 };
            },
            .rgb => |img| blk: {
                const p = img.at(row, col).*;
                break :blk Rgba{ .r = p.r, .g = p.g, .b = p.b, .a = 255 };
            },
            .rgba => |img| img.at(row, col).*,
        };
    }

    /// Set a pixel from an Rgba value, converting as needed.
    pub fn setPixelRgba(self: *PyImage, row: usize, col: usize, px: Rgba) void {
        switch (self.data) {
            .grayscale => |*img| img.at(row, col).* = px.toGray(),
            .rgb => |*img| img.at(row, col).* = Rgb{ .r = px.r, .g = px.g, .b = px.b },
            .rgba => |*img| img.at(row, col).* = px,
        }
    }

    /// Copy pixels from another PyImage to this one.
    /// Both images must have the same dimensions.
    pub fn copyFrom(self: *PyImage, src: PyImage) void {
        switch (self.data) {
            .grayscale => |*dst_img| switch (src.data) {
                .grayscale => |src_img| src_img.copy(dst_img.*),
                .rgb => |src_img| src_img.convertInto(u8, dst_img.*),
                .rgba => |src_img| src_img.convertInto(u8, dst_img.*),
            },
            .rgb => |*dst_img| switch (src.data) {
                .grayscale => |src_img| src_img.convertInto(Rgb, dst_img.*),
                .rgb => |src_img| src_img.copy(dst_img.*),
                .rgba => |src_img| src_img.convertInto(Rgb, dst_img.*),
            },
            .rgba => |*dst_img| switch (src.data) {
                .grayscale => |src_img| src_img.convertInto(Rgba, dst_img.*),
                .rgb => |src_img| src_img.convertInto(Rgba, dst_img.*),
                .rgba => |src_img| src_img.copy(dst_img.*),
            },
        }
    }
};

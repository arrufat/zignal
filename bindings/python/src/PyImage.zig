//! Dynamic image wrapper for the Python bindings: one API over Gray, RGB, and RGBA images.
//! Memory is either owned by the struct or borrowed as a view into an existing image.

const std = @import("std");
const python = @import("python.zig");

const zignal = @import("zignal");
const Image = zignal.Image;
const Rgb = zignal.Rgb(u8);
const Rgba = zignal.Rgba(u8);

pub const PyImage = @This();

/// Pixel format, u8-backed for extern compatibility.
pub const DType = enum(u8) { gray, rgb, rgba };

pub const Variant = union(DType) {
    gray: Image(u8),
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

/// Allocates a PyImage from a concrete Image(T).
/// Use `Ownership.borrowed` for views to avoid a double free.
pub fn createFrom(allocator: std.mem.Allocator, image: anytype, ownership: Ownership) ?*PyImage {
    const p = allocator.create(PyImage) catch {
        python.setMemoryError("PyImage");
        return null;
    };
    switch (@TypeOf(image)) {
        Image(u8) => p.* = .{ .data = .{ .gray = image }, .ownership = ownership },
        Image(Rgb) => p.* = .{ .data = .{ .rgb = image }, .ownership = ownership },
        Image(Rgba) => p.* = .{ .data = .{ .rgba = image }, .ownership = ownership },
        else => {
            allocator.destroy(p);
            return null;
        },
    }
    return p;
}

pub fn rows(self: *const PyImage) u32 {
    return switch (self.data) {
        inline else => |img| img.rows,
    };
}

pub fn cols(self: *const PyImage) u32 {
    return switch (self.data) {
        inline else => |img| img.cols,
    };
}

/// Returns the pixel as Rgba regardless of the underlying storage.
pub fn getPixelRgba(self: *const PyImage, row: u32, col: u32) Rgba {
    return switch (self.data) {
        .gray => |img| blk: {
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

/// Sets a pixel from an Rgba value, converting as needed.
pub fn setPixelRgba(self: *PyImage, row: u32, col: u32, px: Rgba) void {
    switch (self.data) {
        .gray => |*img| img.at(row, col).* = px.to(.gray).y,
        .rgb => |*img| img.at(row, col).* = Rgb{ .r = px.r, .g = px.g, .b = px.b },
        .rgba => |*img| img.at(row, col).* = px,
    }
}

/// Copies pixels from another PyImage into this one.
/// Both images must have the same dimensions.
pub fn copyFrom(self: *PyImage, src: PyImage) void {
    switch (self.data) {
        .gray => |*dst_img| switch (src.data) {
            .gray => |src_img| src_img.copy(dst_img.*),
            inline else => |src_img| src_img.convertInto(python.io, u8, dst_img.*),
        },
        .rgb => |*dst_img| switch (src.data) {
            .rgb => |src_img| src_img.copy(dst_img.*),
            inline else => |src_img| src_img.convertInto(python.io, Rgb, dst_img.*),
        },
        .rgba => |*dst_img| switch (src.data) {
            .rgba => |src_img| src_img.copy(dst_img.*),
            inline else => |src_img| src_img.convertInto(python.io, Rgba, dst_img.*),
        },
    }
}

/// Dispatches an operation to the underlying image variant. `func` takes the underlying image
/// pointer as its first argument, followed by the arguments in `ctx`.
pub fn dispatch(self: *PyImage, ctx: anytype, comptime func: anytype) @TypeOf(@call(.auto, func, .{@as(*Image(u8), undefined)} ++ ctx)) {
    return switch (self.data) {
        inline else => |*img| @call(.auto, func, .{img} ++ ctx),
    };
}

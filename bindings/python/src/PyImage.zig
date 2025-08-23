const std = @import("std");
const zignal = @import("zignal");

const Image = zignal.Image;
const Rgb = zignal.Rgb;
const Rgba = zignal.Rgba;

/// PyImage is a Python-facing dynamic image wrapper used only by the Python bindings.
/// Internally it stores one of Image(u8), Image(Rgb), or Image(Rgba) and centralizes
/// format dispatch behind a single type. Start with RGBA-only; add Gray/RGB incrementally.
pub const PyImage = struct {
    pub const Variant = union(enum) {
        gray: Image(u8),
        rgb: Image(Rgb),
        rgba: Image(Rgba),
    };

    data: Variant,
    owning: bool = true,

    pub fn initRgba(image: Image(Rgba)) PyImage {
        return .{ .data = .{ .rgba = image } };
    }

    pub fn deinit(self: *PyImage, allocator: std.mem.Allocator) void {
        if (self.owning) {
            switch (self.data) {
                .gray => |*img| img.deinit(allocator),
                .rgb => |*img| img.deinit(allocator),
                .rgba => |*img| img.deinit(allocator),
            }
        }
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

    /// Set a pixel from an Rgba value, converting as needed.
    pub fn setPixelRgba(self: *PyImage, row: usize, col: usize, px: Rgba) void {
        switch (self.data) {
            .gray => |*img| img.at(row, col).* = px.toGray(),
            .rgb => |*img| img.at(row, col).* = Rgb{ .r = px.r, .g = px.g, .b = px.b },
            .rgba => |*img| img.at(row, col).* = px,
        }
    }

    /// Copy pixels from another PyImage to this one.
    /// Both images must have the same dimensions.
    pub fn copyFrom(self: *PyImage, src: PyImage) void {
        // The underlying Image type already has a copy method that handles views correctly
        // Note: Image.copy signature is source.copy(destination)
        switch (self.data) {
            .gray => |dst_img| {
                switch (src.data) {
                    .gray => |src_img| src_img.copy(dst_img), // src.copy(dst)
                    .rgb => |src_img| {
                        // Convert RGB to gray while copying
                        for (0..dst_img.rows) |r| {
                            for (0..dst_img.cols) |c| {
                                const rgb_pixel = src_img.at(r, c).*;
                                dst_img.at(r, c).* = rgb_pixel.toGray();
                            }
                        }
                    },
                    .rgba => |src_img| {
                        // Convert RGBA to gray while copying
                        for (0..dst_img.rows) |r| {
                            for (0..dst_img.cols) |c| {
                                const rgba_pixel = src_img.at(r, c).*;
                                dst_img.at(r, c).* = rgba_pixel.toGray();
                            }
                        }
                    },
                }
            },
            .rgb => |dst_img| {
                switch (src.data) {
                    .gray => |src_img| {
                        // Convert gray to RGB while copying
                        for (0..dst_img.rows) |r| {
                            for (0..dst_img.cols) |c| {
                                const gray_val = src_img.at(r, c).*;
                                dst_img.at(r, c).* = Rgb{ .r = gray_val, .g = gray_val, .b = gray_val };
                            }
                        }
                    },
                    .rgb => |src_img| src_img.copy(dst_img), // src.copy(dst)
                    .rgba => |src_img| {
                        // Convert RGBA to RGB while copying (drop alpha)
                        for (0..dst_img.rows) |r| {
                            for (0..dst_img.cols) |c| {
                                const rgba_pixel = src_img.at(r, c).*;
                                dst_img.at(r, c).* = Rgb{ .r = rgba_pixel.r, .g = rgba_pixel.g, .b = rgba_pixel.b };
                            }
                        }
                    },
                }
            },
            .rgba => |dst_img| {
                switch (src.data) {
                    .gray => |src_img| {
                        // Convert gray to RGBA while copying
                        for (0..dst_img.rows) |r| {
                            for (0..dst_img.cols) |c| {
                                const gray_val = src_img.at(r, c).*;
                                dst_img.at(r, c).* = Rgba{ .r = gray_val, .g = gray_val, .b = gray_val, .a = 255 };
                            }
                        }
                    },
                    .rgb => |src_img| {
                        // Convert RGB to RGBA while copying
                        for (0..dst_img.rows) |r| {
                            for (0..dst_img.cols) |c| {
                                const rgb_pixel = src_img.at(r, c).*;
                                dst_img.at(r, c).* = Rgba{ .r = rgb_pixel.r, .g = rgb_pixel.g, .b = rgb_pixel.b, .a = 255 };
                            }
                        }
                    },
                    .rgba => |src_img| src_img.copy(dst_img), // src.copy(dst)
                }
            },
        }
    }
};

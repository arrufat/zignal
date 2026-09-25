//! Images whose pixel type is picked at runtime.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Image = @import("../image.zig").Image;
const Rgb = @import("../color.zig").Rgb(u8);
const Rgba = @import("../color.zig").Rgba(u8);

/// An image in any of the common pixel types. Codecs decode into the one closest to how
/// the file stores it; `into` converts to the type the caller wants.
pub const Any = union(enum) {
    grayscale: Image(u8),
    rgb: Image(Rgb),
    rgba: Image(Rgba),

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

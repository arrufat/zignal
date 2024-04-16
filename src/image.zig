const std = @import("std");
const Allocator = std.mem.Allocator;
const Rgba = @import("color.zig").Rgba;
const as = @import("meta.zig").as;

/// A simple image struct that encapsulates the size and the data.
pub fn Image(comptime T: type) type {
    return struct {
        rows: usize,
        cols: usize,
        data: []T,

        const Self = @This();
        /// Constructs an image of rows and cols size.  If the slice
        /// is owned by this image, deinit should also be called.
        pub fn init(rows: usize, cols: usize, data: []T) Self {
            return .{ .rows = rows, .cols = cols, .data = data };
        }

        pub fn initAlloc(allocator: std.mem.Allocator, rows: usize, cols: usize) !Self {
            var array = std.ArrayList(T).init(allocator);
            try array.resize(rows * cols);
            return .{ .rows = rows, .cols = cols, .data = try array.toOwnedSlice() };
        }

        /// Frees the memory from the image.  It should only be called
        /// if the image owns the memory.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.data);
        }

        /// Returns the optional value at row, col in the image.
        pub fn at(self: Self, row: isize, col: isize) ?*T {
            const irows: isize = @intCast(self.rows);
            const icols: isize = @intCast(self.cols);
            if (row < 0 or col < 0 or row >= irows or col >= icols) {
                return null;
            } else {
                const pos: usize = @intCast(row * icols + col);
                return &self.data[pos];
            }
        }

        /// Flips an image from left to right (mirror effect).
        pub fn flipLeftRight(self: Self) void {
            for (0..self.rows) |r| {
                for (0..self.cols / 2) |c| {
                    const left = r * self.cols + c;
                    const right = r * self.cols + self.cols - c - 1;
                    std.mem.swap(T, &self.data[left], &self.data[right]);
                }
            }
        }

        pub fn interpolateBilinear(self: Self, x: f32, y: f32) ?T {
            const left: isize = @intFromFloat(@floor(x));
            const top: isize = @intFromFloat(@floor(y));
            const right = left + 1;
            const bottom = top + 1;
            if (!(left >= 0 and top >= 0 and right < self.cols and bottom < self.rows)) {
                return null;
            }
            const lr_frac: f32 = x - as(f32, left);
            const tb_frac: f32 = y - as(f32, top);
            const tl: T = self.data[as(usize, top) * self.cols + as(usize, left)];
            const tr: T = self.data[as(usize, top) * self.cols + as(usize, right)];
            const bl: T = self.data[as(usize, bottom) * self.cols + as(usize, left)];
            const br: T = self.data[as(usize, bottom) * self.cols + as(usize, right)];
            var temp: T = undefined;
            switch (@typeInfo(T)) {
                .Int, .Float => {
                    temp = as(T, (1 - tb_frac) * ((1 - lr_frac) * as(f32, tl) +
                        lr_frac * as(f32, tr)) +
                        tb_frac * ((1 - lr_frac) * as(f32, bl) +
                        lr_frac * as(f32, br)));
                },
                .Struct => {
                    inline for (std.meta.fields(T)) |f| {
                        @field(temp, f.name) = as(
                            f.type,
                            (1 - tb_frac) * ((1 - lr_frac) * as(f32, @field(tl, f.name)) +
                                lr_frac * as(f32, @field(tr, f.name))) +
                                tb_frac * ((1 - lr_frac) * as(f32, @field(bl, f.name)) +
                                lr_frac * as(f32, @field(br, f.name))),
                        );
                    }
                },
                else => @compileError("Image(" ++ @typeName(T) ++ ").interpolateBilinear: unsupported image type"),
            }
            return temp;
        }

        /// Resizes an image to fit in out, using bilinear interpolation.
        pub fn resize(self: Self, out: *Self) void {
            const x_scale: f32 = as(f32, self.cols - 1) / as(f32, @max(out.cols - 1, 1));
            const y_scale: f32 = as(f32, self.rows - 1) / as(f32, @max(out.rows - 1, 1));
            var sy: f32 = -y_scale;
            for (0..out.rows) |r| {
                sy += y_scale;
                var sx: f32 = -x_scale;
                for (0..out.cols) |c| {
                    sx += x_scale;
                    out.data[r * out.cols + c] = if (self.interpolateBilinear(sx, sy)) |val| val else std.mem.zeroes(T);
                }
            }
        }

        /// Rotates the image by angle (in radians) from the given center.  It must be freed on the caller side.
        pub fn rotateFrom(self: Self, allocator: Allocator, cx: f32, cy: f32, angle: f32) !Self {
            var array = std.ArrayList(T).init(allocator);
            try array.resize(self.rows * self.cols);
            var rotated = Self.init(self.rows, self.cols, try array.toOwnedSlice());
            const cos = @cos(angle);
            const sin = @sin(angle);
            for (0..self.rows) |r| {
                const y: f32 = @floatFromInt(r);
                for (0..self.cols) |c| {
                    const x: f32 = @floatFromInt(c);
                    const rx = cos * (x - cx) - sin * (y - cy) + cx;
                    const ry = sin * (x - cx) + cos * (y - cy) + cy;
                    rotated.data[r * rotated.cols + c] = if (self.interpolateBilinear(rx, ry)) |val| val else std.mem.zeroes(T);
                }
            }
            return rotated;
        }

        /// Rotates the image by angle (in radians) from the center.  It must be freed on the caller side.
        pub fn rotate(self: Self, allocator: Allocator, angle: f32) !Self {
            return try self.rotateFrom(allocator, @floatFromInt(self.cols / 2), @floatFromInt(self.rows / 2), angle);
        }
    };
}

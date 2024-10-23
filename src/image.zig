const std = @import("std");
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const Allocator = std.mem.Allocator;
const Rgba = @import("colorspace.zig").Rgba;
const convert = @import("colorspace.zig").convert;
const as = @import("meta.zig").as;
const isScalar = @import("meta.zig").isScalar;
const isStruct = @import("meta.zig").isStruct;
const Rectangle = @import("geometry.zig").Rectangle(f32);
const Point2d = @import("point.zig").Point2d(f32);

/// A simple image struct that encapsulates the size and the data.
pub fn Image(comptime T: type) type {
    return struct {
        rows: usize,
        cols: usize,
        data: []T,

        const Self = @This();
        /// Constructs an image of rows and cols size.  If the slice is owned by this image,
        /// deinit should also be called.
        pub fn init(rows: usize, cols: usize, data: []T) Image(T) {
            return .{ .rows = rows, .cols = cols, .data = data };
        }

        pub fn initAlloc(allocator: std.mem.Allocator, rows: usize, cols: usize) !Image(T) {
            var array = std.ArrayList(T).init(allocator);
            try array.resize(rows * cols);
            return .{ .rows = rows, .cols = cols, .data = try array.toOwnedSlice() };
        }

        /// Sets the image rows and cols to zero and frees the memory from the image.  It should
        /// only be called if the image owns the memory.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.rows = 0;
            self.cols = 0;
            allocator.free(self.data);
        }

        /// Returns the number of channels or depth of this image type.
        pub fn channels() usize {
            return switch (@typeInfo(T)) {
                .int, .float => 1,
                .@"struct" => std.meta.fields(T).len,
                .array => |info| info.len,
                else => @compileError("Image(" ++ @typeName(T) ++ " is unsupported."),
            };
        }

        /// Returns true if and only if self and other have the same number of rows, columns and
        /// data size.
        pub fn hasSameShape(self: Self, other: anytype) bool {
            return self.rows == other.rows and self.cols == other.cols and self.data.len == other.data.len;
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

        /// Flips an image from top to bottom (upside down effect).
        pub fn flipTopBottom(self: Self) void {
            for (0..self.rows / 2) |r| {
                for (0..self.cols) |c| {
                    const top = r * self.cols + c;
                    const bottom = (self.rows - r - 1) * self.cols + c;
                    std.mem.swap(T, &self.data[top], &self.data[bottom]);
                }
            }
        }

        /// Performs bilinear interpolation at position x, y.
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
                .int, .float => {
                    temp = as(T, (1 - tb_frac) * ((1 - lr_frac) * as(f32, tl) +
                        lr_frac * as(f32, tr)) +
                        tb_frac * ((1 - lr_frac) * as(f32, bl) +
                        lr_frac * as(f32, br)));
                },
                .@"struct" => {
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
        pub fn resize(self: Self, out: Self) void {
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

        /// Rotates the image by angle (in radians) from center.  It must be freed on the caller side.
        pub fn rotateFrom(self: Self, allocator: Allocator, center: Point2d, angle: f32, rotated: *Self) !void {
            var array = std.ArrayList(T).init(allocator);
            try array.resize(self.rows * self.cols);
            rotated.* = Self.init(self.rows, self.cols, try array.toOwnedSlice());
            const cos = @cos(angle);
            const sin = @sin(angle);
            for (0..self.rows) |r| {
                const y: f32 = @floatFromInt(r);
                for (0..self.cols) |c| {
                    const x: f32 = @floatFromInt(c);
                    const rx = cos * (x - center.x) - sin * (y - center.y) + center.x;
                    const ry = sin * (x - center.x) + cos * (y - center.y) + center.y;
                    rotated.data[r * rotated.cols + c] = if (self.interpolateBilinear(rx, ry)) |val| val else std.mem.zeroes(T);
                }
            }
        }

        /// Rotates the image by angle (in radians) from the center.  It must be freed on the
        /// caller side.
        pub fn rotate(self: Self, allocator: Allocator, angle: f32) !Self {
            return try self.rotateFrom(allocator, .{ .x = self.cols / 2, .y = self.rows / 2 }, angle);
        }

        /// Crops the rectangle out of the image.  If the rectangle is not fully contained in the
        /// image, that area is filled with black/transparent pixels.
        pub fn crop(self: Self, allocator: Allocator, rectangle: Rectangle, chip: *Self) !void {
            const chip_top: isize = @intFromFloat(@round(rectangle.t));
            const chip_left: isize = @intFromFloat(@round(rectangle.l));
            const chip_rows: usize = @intFromFloat(@round(rectangle.height()));
            const chip_cols: usize = @intFromFloat(@round(rectangle.width()));
            chip.* = try Image(T).initAlloc(allocator, chip_rows, chip_cols);
            for (0..chip_rows) |r| {
                const ir: isize = @intCast(r);
                for (0..chip_cols) |c| {
                    const ic: isize = @intCast(c);
                    chip.data[r * chip_cols + c] = if (self.at(@intCast(ir + chip_top), @intCast(ic + chip_left))) |val|
                        val.*
                    else
                        std.mem.zeroes(T);
                }
            }
        }

        /// Computes the integral image of self.
        pub fn integralImage(
            self: Self,
            allocator: Allocator,
            integral: *Image(if (isScalar(T)) f32 else [Self.channels()]f32),
        ) !void {
            switch (@typeInfo(T)) {
                .comptime_int, .int, .comptime_float, .float => {
                    if (!self.hasSameShape(integral.*)) {
                        integral.* = try Image(f32).initAlloc(allocator, self.rows, self.cols);
                    }
                    var tmp: f32 = 0;
                    for (0..self.cols) |c| {
                        tmp += as(f32, (self.data[c]));
                        integral.data[c] = tmp;
                    }
                    for (1..self.rows) |r| {
                        tmp = 0;
                        for (0..self.cols) |c| {
                            const curr_pos = r * self.cols + c;
                            const prev_pos = (r - 1) * self.cols + c;
                            tmp += as(f32, self.data[curr_pos]);
                            integral.data[curr_pos] = tmp + integral.data[prev_pos];
                        }
                    }
                },
                .@"struct" => {
                    if (!self.hasSameShape(integral.*)) {
                        integral.* = try Image([Self.channels()]f32).initAlloc(allocator, self.rows, self.cols);
                    }
                    var tmp = [_]f32{0} ** Self.channels();
                    for (0..self.cols) |c| {
                        inline for (std.meta.fields(T), 0..) |f, i| {
                            tmp[i] += as(f32, @field(self.data[c], f.name));
                            integral.data[c][i] = tmp[i];
                        }
                    }
                    for (1..self.rows) |r| {
                        tmp = [_]f32{0} ** Self.channels();
                        for (0..self.cols) |c| {
                            const curr_pos = r * self.cols + c;
                            const prev_pos = (r - 1) * self.cols + c;
                            inline for (std.meta.fields(T), 0..) |f, i| {
                                tmp[i] += as(f32, @field(self.data[curr_pos], f.name));
                                integral.data[curr_pos][i] = tmp[i] + integral.data[prev_pos][i];
                            }
                        }
                    }
                },
                else => @compileError("Can't compute the integral image of " ++ @typeName(T) ++ "."),
            }
        }

        /// Computes a blurred version of self efficiently by using an integral image.
        pub fn boxBlur(self: Self, allocator: std.mem.Allocator, blurred: *Self, radius: usize) !void {
            if (!self.hasSameShape(blurred.*)) {
                blurred.* = try Image(T).initAlloc(allocator, self.rows, self.cols);
            }
            if (radius == 0 and &self != blurred) {
                for (self.data, blurred.data) |s, *b| b.* = s;
                return;
            }

            switch (@typeInfo(T)) {
                .int, .float => {
                    var integral: Image(f32) = undefined;
                    try self.integralImage(allocator, &integral);
                    defer integral.deinit(allocator);
                    const size = self.rows * self.cols;
                    var pos: usize = 0;
                    var rem: usize = size;
                    const simd_len = std.simd.suggestVectorLength(T) orelse 1;
                    while (pos < size) {
                        const r = pos / self.cols;
                        const c = pos % self.cols;
                        const r1 = r -| radius;
                        const r2 = @min(r + radius, self.rows - 1);
                        const r1_offset = r1 * self.cols;
                        const r2_offset = r2 * self.cols;
                        const r2_r1 = r2 - r1;
                        if (r1 >= radius and r2 <= self.rows - 1 - radius and
                            c >= radius and c <= self.cols - 1 - radius - simd_len and
                            rem >= simd_len)
                        {
                            const c1 = c - radius;
                            const c2 = c + radius;
                            const int11s: @Vector(simd_len, f32) = integral.data[r1_offset + c1 ..][0..simd_len].*;
                            const int12s: @Vector(simd_len, f32) = integral.data[r1_offset + c2 ..][0..simd_len].*;
                            const int21s: @Vector(simd_len, f32) = integral.data[r2_offset + c1 ..][0..simd_len].*;
                            const int22s: @Vector(simd_len, f32) = integral.data[r2_offset + c2 ..][0..simd_len].*;
                            const areas: @Vector(simd_len, f32) = @splat(@as(f32, @floatFromInt(r2_r1 * 2 * radius)));
                            const sums = int22s - int21s - int12s + int11s;
                            const vals: [simd_len]f32 = @round(sums / areas);
                            for (vals, 0..) |val, i| {
                                if (@typeInfo(T) == .int) {
                                    blurred.data[pos + i] = @intFromFloat(@max(std.math.minInt(T), @min(std.math.maxInt(T), val)));
                                } else {
                                    blurred.data[pos + i] = val;
                                }
                            }
                            pos += simd_len;
                            rem -= simd_len;
                        } else {
                            const c1 = c -| radius;
                            const c2 = @min(c + radius, self.cols - 1);
                            const pos11 = r1_offset + c1;
                            const pos12 = r1_offset + c2;
                            const pos21 = r2_offset + c1;
                            const pos22 = r2_offset + c2;
                            const area: f32 = @floatFromInt((r2 - r1) * (c2 - c1));
                            const sum = integral.data[pos22] - integral.data[pos21] - integral.data[pos12] + integral.data[pos11];
                            blurred.data[pos] = switch (@typeInfo(T)) {
                                .int => @intFromFloat(@max(std.math.minInt(T), @min(std.math.maxInt(T), (@round(sum / area))))),
                                .float => as(T, sum / area),
                                else => @compileError("Can't compute the boxBlur image with struct fields of type " ++ @typeName(T) ++ "."),
                            };
                            pos += 1;
                            rem -= 1;
                        }
                    }
                },
                .@"struct" => {
                    var integral: Image([Self.channels()]f32) = undefined;
                    try self.integralImage(allocator, &integral);
                    defer integral.deinit(allocator);
                    const size = self.rows * self.cols;
                    var pos: usize = 0;
                    var rem: usize = size;
                    while (pos < size) {
                        const r = pos / self.cols;
                        const c = pos % self.cols;
                        const r1 = r -| radius;
                        const c1 = c -| radius;
                        const r2 = @min(r + radius, self.rows - 1);
                        const c2 = @min(c + radius, self.cols - 1);
                        const r1_offset = r1 * self.cols;
                        const r2_offset = r2 * self.cols;
                        const pos11 = r1_offset + c1;
                        const pos12 = r1_offset + c2;
                        const pos21 = r2_offset + c1;
                        const pos22 = r2_offset + c2;
                        const area: f32 = @floatFromInt((r2 - r1) * (c2 - c1));
                        inline for (std.meta.fields(T), 0..) |f, i| {
                            const sum = integral.data[pos22][i] - integral.data[pos21][i] - integral.data[pos12][i] + integral.data[pos11][i];
                            @field(blurred.data[pos], f.name) = switch (@typeInfo(f.type)) {
                                .int => @intFromFloat(@max(std.math.minInt(f.type), @min(std.math.maxInt(f.type), @round(sum / area)))),
                                .float => as(f.type, sum / area),
                                else => @compileError("Can't compute the boxBlur image with struct fields of type " ++ @typeName(f.type) ++ "."),
                            };
                        }
                        pos += 1;
                        rem -= 1;
                    }
                },
                else => @compileError("Can't compute the boxBlur image of " ++ @typeName(T) ++ "."),
            }
        }

        /// Computes a sharpened version of self efficiently by using an integral image.
        /// The code is almost exactly the same as in blurBox, except that we compute the
        /// sharpened version as: sharpened = 2 * self - blurred.
        pub fn sharpen(self: Self, allocator: std.mem.Allocator, sharpened: *Self, radius: usize) !void {
            if (!self.hasSameShape(sharpened.*)) {
                sharpened.* = try Image(T).initAlloc(allocator, self.rows, self.cols);
            }
            if (radius == 0) {
                for (self.data, sharpened.data) |s, *b| b.* = s;
                return;
            }

            switch (@typeInfo(T)) {
                .int, .float => {
                    var integral: Image(f32) = undefined;
                    defer integral.deinit(allocator);
                    try self.integralImage(allocator, &integral);
                    const size = self.rows * self.cols;
                    var pos: usize = 0;
                    var rem: usize = size;
                    const simd_len = std.simd.suggestVectorLength(T) orelse 1;
                    const box_areas: @Vector(simd_len, f32) = @splat(2 * radius * 2 * radius);
                    while (pos < size) {
                        const r = pos / self.cols;
                        const c = pos % self.cols;
                        const r1 = r -| radius;
                        const r2 = @min(r + radius, self.rows - 1);
                        const r1_offset = r1 * self.cols;
                        const r2_offset = r2 * self.cols;
                        if (r1 >= radius and r2 <= self.rows - 1 - radius and
                            c >= radius and c <= self.cols - 1 - radius - simd_len and
                            rem >= simd_len)
                        {
                            const c1 = c - radius;
                            const c2 = c + radius;
                            const int11s: @Vector(simd_len, f32) = integral.data[r1_offset + c1 ..][0..simd_len];
                            const int12s: @Vector(simd_len, f32) = integral.data[r1_offset + c2 ..][0..simd_len];
                            const int21s: @Vector(simd_len, f32) = integral.data[r2_offset + c1 ..][0..simd_len];
                            const int22s: @Vector(simd_len, f32) = integral.data[r2_offset + c2 ..][0..simd_len];
                            const sums = int22s - int21s - int12s + int11s;
                            const vals: [simd_len]f32 = @round(sums / box_areas);
                            for (vals, 0..) |val, i| {
                                if (@typeInfo(T) == .int) {
                                    const temp = @max(0, @min(std.math.maxInt(T), as(isize, self.data[pos]) * 2 - @as(isize, val)));
                                    sharpened.data[pos + i] = as(T, temp);
                                } else {
                                    sharpened.data[pos + i] = 2 * self.data[pos] - val;
                                }
                            }
                            pos += simd_len;
                            rem -= simd_len;
                        } else {
                            const c1 = c -| radius;
                            const c2 = @min(c + radius, self.cols - 1);
                            const pos11 = r1_offset + c1;
                            const pos12 = r1_offset + c2;
                            const pos21 = r2_offset + c1;
                            const pos22 = r2_offset + c2;
                            const area: f32 = @floatFromInt((r2 - r1) * (c2 - c1));
                            const sum = integral.data[pos22] - integral.data[pos21] - integral.data[pos12] + integral.data[pos11];
                            sharpened.data[pos] = switch (@typeInfo(T)) {
                                .int => @intFromFloat(@max(std.math.minInt(T), @min(std.math.maxInt(T), @round(sum / area)))),
                                .float => as(T, sum / area),
                            };
                            pos += 1;
                            rem -= 1;
                        }
                    }
                },
                .@"struct" => {
                    var integral: Image([Self.channels()]f32) = undefined;
                    try self.integralImage(allocator, &integral);
                    defer integral.deinit(allocator);
                    const size = self.rows * self.cols;
                    var pos: usize = 0;
                    var rem: usize = size;
                    while (pos < size) {
                        const r = pos / self.cols;
                        const c = pos % self.cols;
                        const r1 = r -| radius;
                        const c1 = c -| radius;
                        const r2 = @min(r + radius, self.rows - 1);
                        const c2 = @min(c + radius, self.cols - 1);
                        const r1_offset = r1 * self.cols;
                        const r2_offset = r2 * self.cols;
                        const pos11 = r1_offset + c1;
                        const pos12 = r1_offset + c2;
                        const pos21 = r2_offset + c1;
                        const pos22 = r2_offset + c2;
                        const area: f32 = @floatFromInt((r2 - r1) * (c2 - c1));
                        inline for (std.meta.fields(T), 0..) |f, i| {
                            const sum = integral.data[pos22][i] - integral.data[pos21][i] - integral.data[pos12][i] + integral.data[pos11][i];
                            @field(sharpened.data[pos], f.name) = switch (@typeInfo(f.type)) {
                                .int => as(f.type, @max(0, @min(std.math.maxInt(f.type), as(isize, @field(self.data[pos], f.name)) * 2 - as(isize, @round(sum / area))))),
                                .float => as(f.type, 2 * @field(self.data[pos], f.name) - sum / area),
                                else => @compileError("Can't compute the sharpen image with struct fields of type " ++ @typeName(f.type) ++ "."),
                            };
                        }
                        pos += 1;
                        rem -= 1;
                    }
                },
                else => @compileError("Can't compute the sharpen image of " ++ @typeName(T) ++ "."),
            }
        }

        /// Applies the sobel filter to self to perform edge detection.
        pub fn sobel(self: Self, allocator: Allocator, out: *Image(u8)) !void {
            if (!self.hasSameShape(out.*)) {
                out.* = try Image(u8).initAlloc(allocator, self.rows, self.cols);
            }
            const vert_filter = [3][3]i32{
                .{ -1, -2, -1 },
                .{ 0, 0, 0 },
                .{ 1, 2, 1 },
            };
            const horz_filter = [3][3]i32{
                .{ -1, 0, 1 },
                .{ -2, 0, 2 },
                .{ -1, 0, 1 },
            };
            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    const pos = r * self.cols + c;
                    const ir: isize = @intCast(r);
                    const ic: isize = @intCast(c);
                    var horz_temp: i32 = 0;
                    var vert_temp: i32 = 0;
                    for (0..vert_filter.len) |m| {
                        const py: isize = ir - 1 + @as(isize, @intCast(m));
                        for (0..vert_filter[0].len) |n| {
                            const px: isize = ic - 1 + @as(isize, @intCast(n));
                            if (self.at(py, px)) |val| {
                                const p: i32 = @intCast(convert(u8, val.*));
                                horz_temp += p * horz_filter[m][n];
                                vert_temp += p * vert_filter[m][n];
                            }
                        }
                    }
                    out.data[pos] = @intFromFloat(@max(0, @min(255, @sqrt(@as(f32, @floatFromInt(horz_temp * horz_temp + vert_temp * vert_temp))))));
                }
            }
        }
    };
}

test "integral image scalar" {
    var image = try Image(u8).initAlloc(std.testing.allocator, 21, 13);
    defer image.deinit(std.testing.allocator);
    for (image.data) |*i| i.* = 1;
    var integral: Image(f32) = undefined;
    try image.integralImage(std.testing.allocator, &integral);
    defer integral.deinit(std.testing.allocator);
    try expectEqual(image.rows, integral.rows);
    try expectEqual(image.cols, integral.cols);
    try expectEqual(image.data.len, integral.data.len);
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            const pos = r * image.cols + c;
            const area_at_pos: f32 = @floatFromInt((r + 1) * (c + 1));
            try expectEqual(area_at_pos, integral.data[pos]);
        }
    }
}

test "integral image struct" {
    var image = try Image(Rgba).initAlloc(std.testing.allocator, 21, 13);
    defer image.deinit(std.testing.allocator);
    for (image.data) |*i| i.* = .{ .r = 1, .g = 1, .b = 1, .a = 1 };
    var integral: Image([4]f32) = undefined;
    try image.integralImage(std.testing.allocator, &integral);

    defer integral.deinit(std.testing.allocator);
    try expectEqual(image.rows, integral.rows);
    try expectEqual(image.cols, integral.cols);
    try expectEqual(image.data.len, integral.data.len);
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            const pos = r * image.cols + c;
            const area_at_pos: f32 = @floatFromInt((r + 1) * (c + 1));
            for (0..4) |i| {
                try expectEqual(area_at_pos, integral.data[pos][i]);
            }
        }
    }
}

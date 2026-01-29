const std = @import("std");
const Allocator = std.mem.Allocator;

const Image = @import("../image.zig").Image;
const Histogram = @import("../image.zig").Histogram;
const border_module = @import("border.zig");
const BorderMode = border_module.BorderMode;
const channel_ops = @import("channel_ops.zig");
const meta = @import("../meta.zig");

pub fn OrderStatisticBlurOps(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Error = error{
            InvalidRadius,
            InvalidPercentile,
            UnsupportedPixelType,
            InvalidTrim,
        };

        pub fn medianBlur(
            image: Image(T),
            allocator: Allocator,
            radius: usize,
            out: Image(T),
        ) !void {
            try Self.percentileBlur(image, allocator, radius, 0.5, .mirror, out);
        }

        pub fn percentileBlur(
            image: Image(T),
            allocator: Allocator,
            radius: usize,
            percentile: f64,
            border: BorderMode,
            out: Image(T),
        ) !void {
            if (image.rows == 0 or image.cols == 0) {
                return;
            }

            if (radius == 0) {
                image.copy(out);
                return;
            }

            if (percentile < 0.0 or percentile > 1.0) {
                return Error.InvalidPercentile;
            }

            const alias = out.isAliased(image);

            var temp_out: Image(T) = .empty;
            defer if (temp_out.data.len != 0) temp_out.deinit(allocator);

            var target: Image(T) = out;
            if (alias) {
                temp_out = try Image(T).initLike(allocator, image);
                target = temp_out;
            }

            switch (@typeInfo(T)) {
                .int => |int_info| {
                    _ = int_info;
                    if (T != u8) return Error.UnsupportedPixelType;
                    const reducer = PercentileReducer{ .percentile = percentile };
                    try applyScalarOp(image, allocator, radius, target, border, reducer);
                },
                .@"struct" => {
                    if (!comptime meta.allFieldsAreU8(T)) return Error.UnsupportedPixelType;
                    const reducer = PercentileReducer{ .percentile = percentile };
                    try applyStructOp(image, allocator, radius, target, border, reducer);
                },
                else => return Error.UnsupportedPixelType,
            }

            if (alias) {
                target.copy(out);
            }
        }

        pub fn minBlur(
            image: Image(T),
            allocator: Allocator,
            radius: usize,
            border: BorderMode,
            out: Image(T),
        ) !void {
            try Self.percentileBlur(image, allocator, radius, 0.0, border, out);
        }

        pub fn maxBlur(
            image: Image(T),
            allocator: Allocator,
            radius: usize,
            border: BorderMode,
            out: Image(T),
        ) !void {
            try Self.percentileBlur(image, allocator, radius, 1.0, border, out);
        }

        pub fn midpointBlur(
            image: Image(T),
            allocator: Allocator,
            radius: usize,
            border: BorderMode,
            out: Image(T),
        ) !void {
            if (image.rows == 0 or image.cols == 0) {
                return;
            }

            if (radius == 0) {
                image.copy(out);
                return;
            }

            const alias = out.isAliased(image);
            var temp_out: Image(T) = .empty;
            defer if (temp_out.data.len != 0) temp_out.deinit(allocator);

            var target: Image(T) = out;
            if (alias) {
                temp_out = try Image(T).initLike(allocator, image);
                target = temp_out;
            }

            const reducer = MidpointReducer{};
            switch (@typeInfo(T)) {
                .int => |int_info| {
                    _ = int_info;
                    if (T != u8) return Error.UnsupportedPixelType;
                    try applyScalarOp(image, allocator, radius, target, border, reducer);
                },
                .@"struct" => {
                    if (!comptime meta.allFieldsAreU8(T)) return Error.UnsupportedPixelType;
                    try applyStructOp(image, allocator, radius, target, border, reducer);
                },
                else => return Error.UnsupportedPixelType,
            }

            if (alias) {
                target.copy(out);
            }
        }

        pub fn alphaTrimmedMeanBlur(
            image: Image(T),
            allocator: Allocator,
            radius: usize,
            trim_fraction: f64,
            border: BorderMode,
            out: Image(T),
        ) !void {
            if (image.rows == 0 or image.cols == 0) {
                return;
            }

            if (!std.math.isFinite(trim_fraction) or trim_fraction < 0.0 or trim_fraction >= 0.5) {
                return Error.InvalidTrim;
            }

            if (radius == 0) {
                image.copy(out);
                return;
            }

            const alias = out.isAliased(image);
            var temp_out: Image(T) = .empty;
            defer if (temp_out.data.len != 0) temp_out.deinit(allocator);

            var target: Image(T) = out;
            if (alias) {
                temp_out = try Image(T).initLike(allocator, image);
                target = temp_out;
            }

            const reducer = AlphaTrimmedMeanReducer{ .trim_fraction = trim_fraction };

            switch (@typeInfo(T)) {
                .int => |int_info| {
                    _ = int_info;
                    if (T != u8) return Error.UnsupportedPixelType;
                    try applyScalarOp(image, allocator, radius, target, border, reducer);
                },
                .@"struct" => {
                    if (!comptime meta.allFieldsAreU8(T)) return Error.UnsupportedPixelType;
                    try applyStructOp(image, allocator, radius, target, border, reducer);
                },
                else => return Error.UnsupportedPixelType,
            }

            if (alias) {
                target.copy(out);
            }
        }

        fn applyStructOp(
            image: Image(T),
            allocator: Allocator,
            radius: usize,
            target: Image(T),
            border: BorderMode,
            reducer: anytype,
        ) !void {
            const num_channels = comptime Image(T).channels();
            const plane_size = image.rows * image.cols;

            const src_planes = try channel_ops.splitChannels(T, image, allocator);
            defer inline for (src_planes) |plane| allocator.free(plane);

            var dst_planes: [num_channels][]u8 = undefined;
            var plane_wrappers: [num_channels]Image(u8) = undefined;

            var allocated: usize = 0;
            defer for (dst_planes[0..allocated]) |plane| allocator.free(plane);

            inline for (src_planes, 0..) |plane, idx| {
                dst_planes[idx] = try allocator.alloc(u8, plane_size);
                allocated += 1;
                plane_wrappers[idx] = Image(u8).initFromSlice(image.rows, image.cols, dst_planes[idx]);

                const src_plane = Image(u8).initFromSlice(image.rows, image.cols, plane);
                try applyScalarOp(src_plane, allocator, radius, plane_wrappers[idx], border, reducer);
            }

            channel_ops.mergeChannels(T, dst_planes, target);
        }

        fn applyScalarOp(
            image: Image(u8),
            allocator: Allocator,
            radius: usize,
            out: Image(u8),
            border: BorderMode,
            reducer_in: anytype,
        ) !void {
            const window = radius * 2 + 1;
            if (window > @as(usize, std.math.maxInt(u32))) return Error.InvalidRadius;

            const alias = out.isAliased(image);

            var temp_out: Image(u8) = .empty;
            defer if (temp_out.data.len != 0) temp_out.deinit(allocator);

            var target: Image(u8) = out;
            if (alias) {
                temp_out = try Image(u8).initLike(allocator, image);
                target = temp_out;
            }

            var column_hists = try allocator.alloc(Histogram(u8), image.cols);
            defer allocator.free(column_hists);

            for (column_hists) |*hist| hist.* = Histogram(u8).init();

            const zero_column = constantHistogram(window, 0);
            const radius_isize: isize = @intCast(radius);
            var reducer = reducer_in;

            for (0..image.cols) |col| {
                var hist = Histogram(u8).init();
                for (0..window) |offset| {
                    const row_idx = @as(isize, @intCast(offset)) - radius_isize;
                    const sample = getPixel(image, border, row_idx, @intCast(col));
                    hist.addValue(sample);
                }
                column_hists[col] = hist;
            }

            for (0..image.rows) |row| {
                var window_hist = Histogram(u8).init();
                for (0..window) |offset| {
                    const col_idx = @as(isize, @intCast(offset)) - radius_isize;
                    if (border_module.resolveIndex(col_idx, @intCast(image.cols), border)) |resolved| {
                        window_hist.addCounts(column_hists[resolved]);
                    } else {
                        window_hist.addCounts(zero_column);
                    }
                }

                const area = @as(usize, @intCast(window_hist.totalPixels()));
                target.at(row, 0).* = try reducer.compute(&window_hist, area);

                for (1..image.cols) |col| {
                    const left_idx = @as(isize, @intCast(col)) - radius_isize - 1;
                    if (border_module.resolveIndex(left_idx, @intCast(image.cols), border)) |resolved| {
                        window_hist.subtractCounts(column_hists[resolved]);
                    } else {
                        window_hist.subtractCounts(zero_column);
                    }

                    const right_idx = @as(isize, @intCast(col)) + radius_isize;
                    if (border_module.resolveIndex(right_idx, @intCast(image.cols), border)) |resolved| {
                        window_hist.addCounts(column_hists[resolved]);
                    } else {
                        window_hist.addCounts(zero_column);
                    }

                    const local_area = @as(usize, @intCast(window_hist.totalPixels()));
                    target.at(row, col).* = try reducer.compute(&window_hist, local_area);
                }

                if (row + 1 == image.rows) break;

                const remove_row = @as(isize, @intCast(row)) - radius_isize;
                const add_row = @as(isize, @intCast(row)) + radius_isize + 1;

                for (0..image.cols) |col| {
                    if (border_module.resolveIndex(remove_row, @intCast(image.rows), border)) |resolved| {
                        const value = image.at(resolved, col).*;
                        column_hists[col].removeValue(value);
                    } else {
                        column_hists[col].removeValue(0);
                    }

                    if (border_module.resolveIndex(add_row, @intCast(image.rows), border)) |resolved| {
                        const value = image.at(resolved, col).*;
                        column_hists[col].addValue(value);
                    } else {
                        column_hists[col].addValue(0);
                    }
                }
            }

            if (alias) {
                target.copy(out);
            }
        }

        fn constantHistogram(count: usize, value: u8) Histogram(u8) {
            var hist = Histogram(u8).init();
            hist.values[value] = @intCast(count);
            return hist;
        }

        fn getPixel(image: Image(u8), border: BorderMode, row: isize, col: isize) u8 {
            const r = border_module.resolveIndex(row, @intCast(image.rows), border);
            const c = border_module.resolveIndex(col, @intCast(image.cols), border);
            if (r) |row_idx| {
                if (c) |col_idx| {
                    return image.at(row_idx, col_idx).*;
                }
            }
            return 0;
        }

        const PercentileReducer = struct {
            percentile: f64,

            fn compute(self: *const @This(), hist: *const Histogram(u8), _: usize) Error!u8 {
                return hist.percentileFraction(self.percentile);
            }
        };

        const MidpointReducer = struct {
            fn compute(_: *const @This(), hist: *const Histogram(u8), _: usize) Error!u8 {
                const min = hist.firstNonZero() orelse 0;
                const max = hist.lastNonZero() orelse min;
                const sum: u16 = @as(u16, min) + @as(u16, max);
                return @intCast((sum + 1) / 2);
            }
        };

        const AlphaTrimmedMeanReducer = struct {
            trim_fraction: f64,

            fn compute(self: *const @This(), hist: *const Histogram(u8), window_area: usize) Error!u8 {
                const total_f = @as(f64, @floatFromInt(window_area));
                const trimmed_total = @floor(self.trim_fraction * total_f);
                const trimmed_each = @as(usize, @intFromFloat(trimmed_total));
                const trim_each = @min(trimmed_each, window_area / 2);

                var total_sum: u64 = 0;
                for (hist.values, 0..) |count, value| {
                    total_sum += @as(u64, count) * @as(u64, value);
                }

                var low_sum: u64 = 0;
                var low_count: usize = 0;
                var remaining = trim_each;
                for (hist.values, 0..) |count, value| {
                    if (remaining == 0) break;
                    const take = @min(@as(usize, count), remaining);
                    low_sum += @as(u64, take) * @as(u64, value);
                    low_count += take;
                    remaining -= take;
                }

                var high_sum: u64 = 0;
                var high_count: usize = 0;
                remaining = trim_each;
                var idx: usize = hist.values.len;
                while (idx > 0 and remaining > 0) : (idx -= 1) {
                    const count = hist.values[idx - 1];
                    if (count == 0) continue;
                    const take = @min(@as(usize, count), remaining);
                    high_sum += @as(u64, take) * @as(u64, idx - 1);
                    high_count += take;
                    remaining -= take;
                }

                const kept_count = window_area - low_count - high_count;
                if (kept_count == 0) return Error.InvalidTrim;

                const kept_sum = total_sum - low_sum - high_sum;
                const rounded = (kept_sum + @as(u64, kept_count) / 2) / @as(u64, kept_count);
                return @intCast(@min(@as(u64, 255), rounded));
            }
        };
    };
}

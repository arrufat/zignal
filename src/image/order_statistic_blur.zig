const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Image = @import("../image.zig").Image;
const Histogram = @import("../image.zig").Histogram;
const histogram = @import("histogram.zig");
const percentileRank = histogram.percentileRank;
const border_module = @import("border.zig");
const BorderMode = border_module.BorderMode;
const channel_ops = @import("channel_ops.zig");
const parallel = @import("../parallel.zig");
const meta = @import("../meta.zig");

pub const Error = error{
    InvalidRadius,
    InvalidPercentile,
    UnsupportedPixelType,
    InvalidTrim,
};

const Vec16 = @Vector(16, u16);

/// Per-column two-level histogram (544 B vs 1 KiB flat): coarse[b] counts values in
/// [16b, 16b+15], fine[b][s] counts value 16b+s. u16 counts are safe because the
/// two-level path only runs for window <= 255 (population <= 255^2 < 65536).
const TwoLevelColumn = struct {
    /// u16 counts hold up to window^2 samples, so the two-level path requires this.
    const max_window = 255;

    coarse: [16]u16 align(32) = @splat(0),
    fine: [16][16]u16 align(32) = @splat(@splat(0)),

    inline fn addValue(self: *TwoLevelColumn, v: u8) void {
        self.coarse[v >> 4] += 1;
        self.fine[v >> 4][v & 15] += 1;
    }

    inline fn removeValue(self: *TwoLevelColumn, v: u8) void {
        self.coarse[v >> 4] -= 1;
        self.fine[v >> 4][v & 15] -= 1;
    }
};

const BucketSel = struct { bucket: usize, cum: u32 };

/// Locates the coarse bucket containing `rank` (<=16 scalar steps) and the cumulative
/// count below it. Together with `scanFine` this mirrors the cumulative scan of
/// `histogram.percentileWithTotal` exactly.
inline fn pickBucket(rank: usize, coarse_win: Vec16) BucketSel {
    const coarse: [16]u16 = coarse_win;
    var cum: u32 = 0;
    var bucket: usize = 0;
    while (bucket < 16) : (bucket += 1) {
        if (cum + coarse[bucket] > rank) break;
        cum += coarse[bucket];
    }
    std.debug.assert(bucket < 16);
    return .{ .bucket = bucket, .cum = cum };
}

/// Full rebuild of one bucket's fine row: one 16-lane add per window column.
inline fn buildFineRow(bucket: usize, window_cols: []const *const TwoLevelColumn) Vec16 {
    var fine_vec: Vec16 = @splat(0);
    for (window_cols) |col| fine_vec += @as(Vec16, col.fine[bucket]);
    return fine_vec;
}

/// Scans the bucket's 16 fine bins, continuing the cumulative count from `pickBucket`.
inline fn scanFine(rank: usize, cum_below: u32, bucket: usize, fine_win: Vec16) u8 {
    const fine: [16]u16 = fine_win;
    var cum = cum_below;
    var sub: usize = 0;
    while (sub < 16) : (sub += 1) {
        cum += fine[sub];
        if (cum > rank) break;
    }
    std.debug.assert(sub < 16);
    return @intCast(bucket * 16 + sub);
}

/// Constant-rank order-statistic filter over two-level histograms. Same window,
/// border, and rank semantics as the flat path (bit-identical results), but the
/// per-pixel cost is ~2 coarse vector ops + 2 fine vector ops: the fine row of the
/// selected bucket is maintained incrementally alongside the coarse window and only
/// rebuilt (O(window)) when the selected bucket changes between adjacent pixels.
fn applyScalarOpTwoLevel(
    io: Io,
    image: Image(u8),
    allocator: Allocator,
    radius: usize,
    out: Image(u8),
    border: BorderMode,
    rank: usize,
) !void {
    // Aliasing is resolved by the public entry points (percentileBlur et al).
    std.debug.assert(out.data.ptr != image.data.ptr);
    const window = radius * 2 + 1;
    const rows = image.rows;
    const cols = image.cols;
    // Seeding a band costs one window of rows, so bands need only be one window tall.
    const bands = parallel.bandCountFor(rows, cols, window);

    // Out-of-range columns contribute `window` zeros, like the flat path's zero_column.
    var zero_col: TwoLevelColumn = .{};
    zero_col.coarse[0] = @intCast(window);
    zero_col.fine[0][0] = @intCast(window);

    const ctx: TwoLevelBands = .{
        .image = image,
        .out = out,
        .radius = radius,
        .border = border,
        .rank = rank,
        .zero_col = &zero_col,
        .column_hists = try allocator.alloc(TwoLevelColumn, bands * cols),
        .col_ptrs = try allocator.alloc(*const TwoLevelColumn, bands * (cols + window - 1)),
    };
    defer allocator.free(ctx.column_hists);
    defer allocator.free(ctx.col_ptrs);
    parallel.forRowBands(io, rows, bands, &ctx, TwoLevelBands.band);
}

const TwoLevelBands = struct {
    image: Image(u8),
    out: Image(u8),
    radius: usize,
    border: BorderMode,
    rank: usize,
    zero_col: *const TwoLevelColumn,
    /// `cols` column histograms per band.
    column_hists: []TwoLevelColumn,
    /// `cols + window - 1` window-position pointers per band.
    col_ptrs: []*const TwoLevelColumn,

    fn band(ctx: *const TwoLevelBands, b: usize, r0: usize, r1: usize) void {
        const image = ctx.image;
        const out = ctx.out;
        const border = ctx.border;
        const rank = ctx.rank;
        const window = ctx.radius * 2 + 1;
        const rows = image.rows;
        const cols = image.cols;
        const radius_isize: isize = @intCast(ctx.radius);
        const column_hists = ctx.column_hists[b * cols ..][0..cols];
        const col_ptrs = ctx.col_ptrs[b * (cols + window - 1) ..][0 .. cols + window - 1];

        // Column histograms of the window centred on the band's first row.
        for (column_hists) |*hist| hist.* = .{};
        for (0..window) |offset| {
            const row_idx = @as(isize, @intCast(r0 + offset)) - radius_isize;
            if (border_module.resolveIndex(row_idx, @intCast(rows), border)) |rr| {
                for (column_hists, 0..) |*hist, col| hist.addValue(image.at(rr, col).*);
            } else {
                for (column_hists) |*hist| hist.addValue(0);
            }
        }

        // Column border resolution is row-invariant, so it is hoisted out of the pixel loops.
        for (col_ptrs, 0..) |*ptr, i| {
            const idx = @as(isize, @intCast(i)) - radius_isize;
            ptr.* = if (border_module.resolveIndex(idx, @intCast(cols), border)) |resolved|
                &column_hists[resolved]
            else
                ctx.zero_col;
        }

        for (r0..r1) |row| {
            // Per-row: the vertical slide mutates the column histograms, so the cache cannot survive a row.
            var coarse_win: Vec16 = @splat(0);
            for (col_ptrs[0..window]) |ptr| coarse_win += @as(Vec16, ptr.coarse);

            var sel = pickBucket(rank, coarse_win);
            var cached_bucket = sel.bucket;
            var fine_win = buildFineRow(cached_bucket, col_ptrs[0..window]);
            out.at(row, 0).* = scanFine(rank, sel.cum, cached_bucket, fine_win);

            for (1..cols) |col| {
                const leaving = col_ptrs[col - 1];
                const entering = col_ptrs[col + window - 1];
                coarse_win -= @as(Vec16, leaving.coarse);
                coarse_win += @as(Vec16, entering.coarse);
                // Unconditional so fine_win tracks cached_bucket on every slide; the leaving column is in fine_win, so no underflow.
                fine_win -= @as(Vec16, leaving.fine[cached_bucket]);
                fine_win += @as(Vec16, entering.fine[cached_bucket]);

                sel = pickBucket(rank, coarse_win);
                if (sel.bucket != cached_bucket) {
                    cached_bucket = sel.bucket;
                    fine_win = buildFineRow(cached_bucket, col_ptrs[col .. col + window]);
                }
                std.debug.assert(@reduce(.Add, fine_win) == @as([16]u16, coarse_win)[cached_bucket]);
                out.at(row, col).* = scanFine(rank, sel.cum, cached_bucket, fine_win);
            }

            if (row + 1 == r1) break;

            const remove_row = border_module.resolveIndex(@as(isize, @intCast(row)) - radius_isize, @intCast(rows), border);
            const add_row = border_module.resolveIndex(@as(isize, @intCast(row)) + radius_isize + 1, @intCast(rows), border);
            for (column_hists, 0..) |*hist, col| {
                hist.removeValue(if (remove_row) |rr| image.at(rr, col).* else 0);
                hist.addValue(if (add_row) |ar| image.at(ar, col).* else 0);
            }
        }
    }
};

fn applyScalarOp(
    io: Io,
    image: Image(u8),
    allocator: Allocator,
    radius: usize,
    out: Image(u8),
    border: BorderMode,
    reducer_in: anytype,
) !void {
    // Reducers expressible as a constant rank over the window (median/percentile/
    // min/max) declare rankFor and take the two-level fast path; u16 counts require
    // window <= 255 (larger radii keep the flat u32 path). The population is always
    // window^2, so the rank is constant for the whole plane.
    const window = radius * 2 + 1;
    if (@hasDecl(@TypeOf(reducer_in), "rankFor") and window <= TwoLevelColumn.max_window) {
        return applyScalarOpTwoLevel(io, image, allocator, radius, out, border, reducer_in.rankFor(window * window));
    }
    return applyScalarOpFlat(io, image, allocator, radius, out, border, reducer_in);
}

fn applyScalarOpFlat(
    io: Io,
    image: Image(u8),
    allocator: Allocator,
    radius: usize,
    out: Image(u8),
    border: BorderMode,
    reducer_in: anytype,
) !void {
    const window = radius * 2 + 1;
    if (window > @as(usize, std.math.maxInt(u32))) return Error.InvalidRadius;

    // Aliasing is resolved by the `run` dispatcher.
    std.debug.assert(out.data.ptr != image.data.ptr);

    const bands = parallel.bandCountFor(image.rows, image.cols, window);
    const Bands = FlatBands(@TypeOf(reducer_in));
    const ctx: Bands = .{
        .image = image,
        .out = out,
        .radius = radius,
        .border = border,
        .reducer = reducer_in,
        .column_hists = try allocator.alloc(Histogram(u8), bands * image.cols),
        .errors = try allocator.alloc(?Error, bands),
    };
    defer allocator.free(ctx.column_hists);
    defer allocator.free(ctx.errors);
    @memset(ctx.errors, null);
    parallel.forRowBands(io, image.rows, bands, &ctx, Bands.band);
    for (ctx.errors) |err| if (err) |e| return e;
}

fn FlatBands(comptime Reducer: type) type {
    return struct {
        image: Image(u8),
        out: Image(u8),
        radius: usize,
        border: BorderMode,
        reducer: Reducer,
        /// `cols` column histograms per band.
        column_hists: []Histogram(u8),
        /// First reducer error per band, reported after the group.
        errors: []?Error,

        fn band(ctx: *const @This(), b: usize, r0: usize, r1: usize) void {
            ctx.errors[b] = if (ctx.bandRows(b, r0, r1)) null else |err| err;
        }

        fn bandRows(ctx: *const @This(), b: usize, r0: usize, r1: usize) Error!void {
            const image = ctx.image;
            const out = ctx.out;
            const border = ctx.border;
            const window = ctx.radius * 2 + 1;
            const radius_isize: isize = @intCast(ctx.radius);
            const column_hists = ctx.column_hists[b * image.cols ..][0..image.cols];
            const zero_column = constantHistogram(window, 0);
            var reducer = ctx.reducer;

            for (column_hists, 0..) |*hist, col| {
                hist.* = Histogram(u8).init();
                for (0..window) |offset| {
                    const row_idx = @as(isize, @intCast(r0 + offset)) - radius_isize;
                    hist.addValue(border_module.getPixel(u8, image, row_idx, @intCast(col), border));
                }
            }

            for (r0..r1) |row| {
                var window_hist = Histogram(u8).init();
                for (0..window) |offset| {
                    const col_idx = @as(isize, @intCast(offset)) - radius_isize;
                    if (border_module.resolveIndex(col_idx, @intCast(image.cols), border)) |resolved| {
                        window_hist.addCounts(&column_hists[resolved]);
                    } else {
                        window_hist.addCounts(&zero_column);
                    }
                }

                // Border samples are counted too, so the population is always window*window.
                const area = window * window;
                out.at(row, 0).* = try reducer.compute(&window_hist, area);

                for (1..image.cols) |col| {
                    const left_idx = @as(isize, @intCast(col)) - radius_isize - 1;
                    if (border_module.resolveIndex(left_idx, @intCast(image.cols), border)) |resolved| {
                        window_hist.subtractCounts(&column_hists[resolved]);
                    } else {
                        window_hist.subtractCounts(&zero_column);
                    }

                    const right_idx = @as(isize, @intCast(col)) + radius_isize;
                    if (border_module.resolveIndex(right_idx, @intCast(image.cols), border)) |resolved| {
                        window_hist.addCounts(&column_hists[resolved]);
                    } else {
                        window_hist.addCounts(&zero_column);
                    }

                    out.at(row, col).* = try reducer.compute(&window_hist, area);
                }

                if (row + 1 == r1) break;

                const remove_row = @as(isize, @intCast(row)) - radius_isize;
                const add_row = @as(isize, @intCast(row)) + radius_isize + 1;

                for (0..image.cols) |col| {
                    if (border_module.resolveIndex(remove_row, @intCast(image.rows), border)) |resolved| {
                        column_hists[col].removeValue(image.at(resolved, col).*);
                    } else {
                        column_hists[col].removeValue(0);
                    }

                    if (border_module.resolveIndex(add_row, @intCast(image.rows), border)) |resolved| {
                        column_hists[col].addValue(image.at(resolved, col).*);
                    } else {
                        column_hists[col].addValue(0);
                    }
                }
            }
        }
    };
}

fn constantHistogram(count: usize, value: u8) Histogram(u8) {
    var hist = Histogram(u8).init();
    hist.values[value] = @intCast(count);
    return hist;
}

const PercentileReducer = struct {
    percentile: f64,

    fn compute(self: *const @This(), hist: *const Histogram(u8), area: usize) Error!u8 {
        return histogram.percentileWithTotal(&hist.values, self.percentile, area);
    }

    /// Declares this reducer rank-expressible: the two-level path serves it as a
    /// constant-rank selection over the window population.
    fn rankFor(self: @This(), population: usize) usize {
        return percentileRank(self.percentile, population);
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
        const trimmed_each: usize = @trunc(trimmed_total);
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

pub fn OrderStatisticBlurOps(comptime T: type) type {
    return struct {
        const Self = @This();

        pub fn medianBlur(
            image: Image(T),
            io: Io,
            out: Image(T),
            allocator: Allocator,
            radius: usize,
        ) !void {
            try Self.percentileBlur(image, io, out, allocator, radius, 0.5, .mirror);
        }

        pub fn percentileBlur(
            image: Image(T),
            io: Io,
            out: Image(T),
            allocator: Allocator,
            radius: usize,
            percentile: f64,
            border: BorderMode,
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

            try run(image, io, out, allocator, radius, border, PercentileReducer{ .percentile = percentile });
        }

        pub fn minBlur(
            image: Image(T),
            io: Io,
            out: Image(T),
            allocator: Allocator,
            radius: usize,
            border: BorderMode,
        ) !void {
            try Self.percentileBlur(image, io, out, allocator, radius, 0.0, border);
        }

        pub fn maxBlur(
            image: Image(T),
            io: Io,
            out: Image(T),
            allocator: Allocator,
            radius: usize,
            border: BorderMode,
        ) !void {
            try Self.percentileBlur(image, io, out, allocator, radius, 1.0, border);
        }

        pub fn midpointBlur(
            image: Image(T),
            io: Io,
            out: Image(T),
            allocator: Allocator,
            radius: usize,
            border: BorderMode,
        ) !void {
            if (image.rows == 0 or image.cols == 0) {
                return;
            }

            if (radius == 0) {
                image.copy(out);
                return;
            }

            try run(image, io, out, allocator, radius, border, MidpointReducer{});
        }

        pub fn alphaTrimmedMeanBlur(
            image: Image(T),
            io: Io,
            out: Image(T),
            allocator: Allocator,
            radius: usize,
            trim_fraction: f64,
            border: BorderMode,
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

            try run(image, io, out, allocator, radius, border, AlphaTrimmedMeanReducer{ .trim_fraction = trim_fraction });
        }

        /// Alias-safe dispatch shared by every entry point: route through a temp image
        /// when out aliases image, then pick the scalar or per-plane path by pixel type.
        fn run(
            image: Image(T),
            io: Io,
            out: Image(T),
            allocator: Allocator,
            radius: usize,
            border: BorderMode,
            reducer: anytype,
        ) !void {
            const alias = out.data.ptr == image.data.ptr;

            var temp_out: Image(T) = .empty;
            defer temp_out.deinit(allocator);

            var target: Image(T) = out;
            if (alias) {
                temp_out = try .initLike(allocator, image);
                target = temp_out;
            }

            switch (@typeInfo(T)) {
                .int => {
                    if (T != u8) return Error.UnsupportedPixelType;
                    try applyScalarOp(io, image, allocator, radius, target, border, reducer);
                },
                .@"struct" => {
                    if (!comptime meta.allFieldsAreU8(T)) return Error.UnsupportedPixelType;
                    try applyStructOp(image, io, allocator, radius, target, border, reducer);
                },
                else => return Error.UnsupportedPixelType,
            }

            if (alias) {
                target.copy(out);
            }
        }

        fn applyStructOp(
            image: Image(T),
            io: Io,
            allocator: Allocator,
            radius: usize,
            target: Image(T),
            border: BorderMode,
            reducer: anytype,
        ) !void {
            const num_channels = comptime Image(T).channels();
            const plane_size = image.rows * image.cols;

            const src_planes = try channel_ops.splitChannels(T, io, image, allocator);
            defer inline for (src_planes) |plane| allocator.free(plane);

            const dst_planes = try channel_ops.allocPlanes(u8, num_channels, allocator, plane_size);
            defer for (dst_planes) |plane| allocator.free(plane);

            inline for (src_planes, dst_planes) |src_data, dst_data| {
                const src_plane = Image(u8).initFromSlice(image.rows, image.cols, src_data);
                const dst_plane = Image(u8).initFromSlice(image.rows, image.cols, dst_data);
                try applyScalarOp(io, src_plane, allocator, radius, dst_plane, border, reducer);
            }

            channel_ops.mergeChannels(T, io, dst_planes, target);
        }
    };
}

test "two-level rank filter matches flat histogram path" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x9E3779B97F4A7C15);
    const random = prng.random();

    const sizes = [_][2]u32{ .{ 1, 1 }, .{ 1, 9 }, .{ 9, 1 }, .{ 5, 5 }, .{ 24, 17 }, .{ 40, 70 } };
    const radii = [_]usize{ 1, 2, 4, 9, 15, 31 };
    const borders = [_]BorderMode{ .zero, .mirror, .replicate, .wrap };
    const percentiles = [_]f64{ 0.0, 0.13, 0.5, 0.77, 1.0 };

    for (sizes) |size| {
        var img = try Image(u8).init(allocator, size[0], size[1]);
        defer img.deinit(allocator);
        for (img.data) |*px| px.* = random.int(u8);

        var flat = try Image(u8).initLike(allocator, img);
        defer flat.deinit(allocator);
        var two = try Image(u8).initLike(allocator, img);
        defer two.deinit(allocator);

        for (radii) |radius| {
            for (borders) |mode| {
                for (percentiles) |p| {
                    const window = radius * 2 + 1;
                    const flat_reducer = PercentileReducer{ .percentile = p };
                    try applyScalarOpFlat(std.Io.Threaded.global_single_threaded.io(), img, allocator, radius, flat, mode, flat_reducer);
                    try applyScalarOpTwoLevel(std.Io.Threaded.global_single_threaded.io(), img, allocator, radius, two, mode, flat_reducer.rankFor(window * window));
                    try testing.expectEqualSlices(u8, flat.data, two.data);
                }
            }
        }
    }

    // Adversarial fills for the fine-row cache: constant (maximum reuse), alternating
    // stripes (the selected bucket flips on every slide, exercising the unconditional
    // slide-update invariant), and a horizontal ramp (adjacent-bucket transitions).
    for (0..3) |pattern| {
        var img = try Image(u8).init(allocator, 24, 33);
        defer img.deinit(allocator);
        for (0..img.rows) |r| {
            for (0..img.cols) |c| {
                img.at(r, c).* = switch (pattern) {
                    0 => 128,
                    1 => if (c % 2 == 0) 0 else 255,
                    else => @intCast((c * 255) / (img.cols - 1)),
                };
            }
        }

        var flat = try Image(u8).initLike(allocator, img);
        defer flat.deinit(allocator);
        var two = try Image(u8).initLike(allocator, img);
        defer two.deinit(allocator);

        for ([_]usize{ 2, 9 }) |radius| {
            for ([_]BorderMode{ .mirror, .zero }) |mode| {
                for ([_]f64{ 0.0, 0.5, 1.0 }) |p| {
                    const window = radius * 2 + 1;
                    const flat_reducer = PercentileReducer{ .percentile = p };
                    try applyScalarOpFlat(std.Io.Threaded.global_single_threaded.io(), img, allocator, radius, flat, mode, flat_reducer);
                    try applyScalarOpTwoLevel(std.Io.Threaded.global_single_threaded.io(), img, allocator, radius, two, mode, flat_reducer.rankFor(window * window));
                    try testing.expectEqualSlices(u8, flat.data, two.data);
                }
            }
        }
    }

    // In-place aliasing through the public dispatch.
    var img = try Image(u8).init(allocator, 9, 7);
    defer img.deinit(allocator);
    for (img.data) |*px| px.* = random.int(u8);
    var expected = try Image(u8).initLike(allocator, img);
    defer expected.deinit(allocator);
    try OrderStatisticBlurOps(u8).medianBlur(img, std.Io.Threaded.global_single_threaded.io(), expected, allocator, 2);
    try OrderStatisticBlurOps(u8).medianBlur(img, std.Io.Threaded.global_single_threaded.io(), img, allocator, 2);
    try testing.expectEqualSlices(u8, expected.data, img.data);
}

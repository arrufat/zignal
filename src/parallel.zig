//! Row-band parallelism for image filters on an `Io` pool.
//!
//! Filters split their rows into contiguous bands and run one task per band through
//! `Io.Group`; a single-threaded `Io` runs the bands inline, in order. Band functions never
//! allocate and never touch another band's rows, so the output is identical to a serial run.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// Io for products far below the band floor (fixed-size fits, 3x3 colour statistics): no
/// band is ever spawned, so the value is never used; `failing` also rejects any accidental
/// real I/O and works on freestanding targets.
pub const inline_io: Io = .failing;

/// Below this many pixels per band the task hand-off costs more than the work.
const min_pixels_per_band: usize = 32 * 1024;

var cpu_count: std.atomic.Value(usize) = .init(0);

/// Logical CPUs, queried once (`getCpuCount` is a syscall) and cached.
fn cpuCount() usize {
    const cached = cpu_count.load(.monotonic);
    if (cached != 0) return cached;
    const n = std.Thread.getCpuCount() catch 1;
    cpu_count.store(n, .monotonic);
    return n;
}

/// Bands for a `rows`×`cols` job: one per CPU, at least `min_pixels_per_band` each.
pub fn bandCount(rows: usize, cols: usize) usize {
    if (builtin.single_threaded or rows == 0) return 1;
    const cpus = cpuCount();
    const by_size = @max(1, (rows * cols) / min_pixels_per_band);
    return @min(cpus, by_size, rows);
}

/// `bandCount` with bands at least `min_band_rows` tall, for passes that re-seed per-band
/// state (column sums, histograms, halo rows) at the top of every band.
pub fn bandCountFor(rows: usize, cols: usize, min_band_rows: usize) usize {
    return @max(1, @min(bandCount(rows, cols), rows / @max(1, min_band_rows)));
}

/// Runs `func(ctx, band, row_start, row_end)` for `bands` contiguous row bands of `[0, rows)`.
pub fn forRowBands(io: Io, rows: usize, bands: usize, ctx: anytype, comptime func: anytype) void {
    if (bands <= 1 or rows == 0) return func(ctx, 0, 0, rows);
    var group: Io.Group = .init;
    for (0..bands) |band| {
        group.async(io, func, .{ ctx, band, rows * band / bands, rows * (band + 1) / bands });
    }
    group.await(io) catch {};
}

/// `forRowBands` for fallible band functions: the first error any band returns is the result.
pub fn forRowBandsTry(io: Io, rows: usize, bands: usize, ctx: anytype, comptime func: anytype) ErrorSetOf(func)!void {
    if (bands <= 1 or rows == 0) return func(ctx, 0, 0, rows);
    const Code = @Int(.unsigned, @bitSizeOf(anyerror));
    const Wrap = struct {
        fn run(first: *std.atomic.Value(Code), c: @TypeOf(ctx), band: usize, r0: usize, r1: usize) void {
            func(c, band, r0, r1) catch |err| {
                _ = first.cmpxchgStrong(0, @intFromError(err), .monotonic, .monotonic);
            };
        }
    };
    var first: std.atomic.Value(Code) = .init(0);
    var group: Io.Group = .init;
    for (0..bands) |band| {
        group.async(io, Wrap.run, .{ &first, ctx, band, rows * band / bands, rows * (band + 1) / bands });
    }
    group.await(io) catch {};
    const code = first.load(.monotonic);
    if (code != 0) {
        const E = ErrorSetOf(func);
        const empty = comptime if (@typeInfo(E).error_set.error_names) |names| names.len == 0 else false;
        if (empty) unreachable;
        return @errorCast(@errorFromInt(code));
    }
}

fn ErrorSetOf(comptime func: anytype) type {
    return @typeInfo(@typeInfo(@TypeOf(func)).@"fn".return_type.?).error_union.error_set;
}

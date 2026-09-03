//! Row-band parallelism for image filters on an `Io` pool.
//!
//! Filters split their rows into contiguous bands and run one task per band through
//! `Io.Group`; a single-threaded `Io` runs the bands inline, in order. Band functions never
//! allocate and never touch another band's rows, so the output is identical to a serial run.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// Below this many pixels per band the task hand-off costs more than the work.
const min_pixels_per_band: usize = 32 * 1024;

/// Bands for a `rows`×`cols` job: one per CPU, at least `min_pixels_per_band` each.
pub fn bandCount(rows: usize, cols: usize) usize {
    if (builtin.single_threaded or rows == 0) return 1;
    const cpus = std.Thread.getCpuCount() catch 1;
    const by_size = @max(1, (rows * cols) / min_pixels_per_band);
    return @min(cpus, by_size, rows);
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

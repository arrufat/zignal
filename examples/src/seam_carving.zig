const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

const zignal = @import("zignal");
const Image = zignal.Image;
const isColor = zignal.color.isColor;
const Rgb = zignal.Rgb(u8);
const Rgba = zignal.Rgba(u8);
const Gray = zignal.Gray(u8);

pub const std_options: std.Options = .{
    .logFn = if (builtin.cpu.arch.isWasm()) @import("js.zig").logFn else std.log.defaultLog,
    .log_level = if (builtin.mode == .Debug) .debug else .info,
};

pub fn computeEnergy(
    edges: Image(u8),
    energy: *Image(u32),
) void {
    assert(edges.rows == energy.rows and edges.cols == energy.cols);
    const rows = edges.rows;
    const cols = edges.cols;
    for (0..cols) |c| energy.data[c] = edges.data[c];
    for (1..rows) |r| {
        for (0..cols) |c| {
            var min: u32 = std.math.maxInt(u32);
            var i: isize = -1;
            while (i <= 1) : (i += 1) {
                var x: isize = @as(isize, @intCast(c)) + i;
                if (x == energy.cols) x = @intCast(energy.cols - 1);
                const y: isize = @as(isize, @intCast(r)) - 1;
                if (energy.atOrNull(y, x)) |val| {
                    min = @min(val.*, min);
                }
            }
            energy.at(r, c).* = edges.at(r, c).* + min;
        }
    }
}

pub fn computeSeam(energy: Image(u32), seam: []usize) void {
    assert(energy.rows == seam.len);
    const row: usize = energy.rows - 1;
    seam[row] = 0;
    for (0..energy.cols) |c| {
        if (energy.at(row, c).* < energy.at(row, seam[row]).*) {
            seam[row] = c;
        }
    }

    var y: isize = @intCast(energy.rows - 2);
    while (y >= 0) : (y -= 1) {
        const r: usize = @intCast(y);
        seam[r] = seam[r + 1];
        var i: isize = -1;
        while (i <= 1) : (i += 1) {
            var x: isize = @as(isize, @intCast(seam[r + 1])) + i;
            if (x == energy.cols) x = @intCast(energy.cols - 1);
            if (energy.atOrNull(y, x)) |curr| {
                if (energy.atOrNull(y, @intCast(seam[r]))) |prev| {
                    if (curr.* < prev.*) {
                        seam[r] = @intCast(x);
                    }
                }
            }
        }
    }
}

pub fn removeSeam(comptime T: type, image: *Image(T), seam: []const usize) void {
    assert(image.rows == seam.len);
    const size = image.rows * image.cols;
    var pos: usize = 0;

    for (0..image.rows) |r| {
        const seam_col = seam[r];
        const row_start = r * image.cols;

        // Copy left segment (columns 0 to seam_col-1)
        if (seam_col > 0) {
            @memmove(image.data[pos..][0..seam_col], image.data[row_start..][0..seam_col]);
            pos += seam_col;
        }

        // Copy right segment (columns seam_col+1 to cols-1)
        const right_start = seam_col + 1;
        if (right_start < image.cols) {
            const right_count = image.cols - right_start;
            @memmove(image.data[pos..][0..right_count], image.data[row_start..][right_start..][0..right_count]);
            pos += right_count;
        }
    }

    image.cols -= 1;
    image.data = image.data[0..(size - image.rows)];
}

pub export fn seam_carve(rgba_ptr: [*]Rgba, rows: usize, cols: usize, extra_ptr: ?[*]u8, extra_len: usize, seam_ptr: [*]usize, seam_size: usize) void {
    assert(seam_size == rows);
    const size = rows * cols;
    var image: Image(Rgba) = .initFromSlice(rows, cols, rgba_ptr[0..size]);

    const allocator: std.mem.Allocator = blk: {
        if (extra_ptr) |ptr| {
            @setRuntimeSafety(true);
            assert(extra_len >= size * 13); // Need at least 13x for sobel buffers
            var fba: std.heap.FixedBufferAllocator = .init(ptr[0..extra_len]);
            break :blk fba.allocator();
        } else if (builtin.cpu.arch.isWasm() and builtin.os.tag == .freestanding) {
            @panic("ERROR: extra_ptr can't be null when running in WebAssembly.");
        } else if (builtin.link_libc) {
            break :blk std.heap.c_allocator;
        } else {
            break :blk std.heap.page_allocator;
        }
    };

    var edges = Image(u8).init(allocator, rows, cols) catch @panic("OOM");
    defer edges.deinit(allocator);
    image.sobel(allocator, edges) catch @panic("OOM");

    var energy_map = Image(u32).init(allocator, image.rows, image.cols) catch @panic("OOM");
    defer energy_map.deinit(allocator);
    computeEnergy(edges, &energy_map);

    const seam = seam_ptr[0..seam_size];
    computeSeam(energy_map, seam);

    removeSeam(Rgba, &image, seam);
}

pub export fn transpose(rgba_ptr: [*]Rgba, rows: usize, cols: usize) void {
    for (0..rows) |r| {
        for (0..cols) |c| {
            const orig_pos = r * cols + c;
            const tran_pos = c * rows + r;
            const temp = rgba_ptr[orig_pos];
            rgba_ptr[orig_pos] = rgba_ptr[tran_pos];
            rgba_ptr[tran_pos] = temp;
        }
    }
}

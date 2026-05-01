//! Color quantization primitives shared by sixel, kitty, and GIF codecs.
//!
//! Provides:
//! - `medianCut`: adaptive palette generation via the median-cut algorithm.
//! - `ColorLookupTable`: 5-bit-per-channel 32x32x32 LUT for fast nearest-color lookup,
//!   built once per palette and queried many times.
//! - Fixed palette generators: 6x7x6 (252 colors), web-safe 216, VGA-16.

const std = @import("std");
const Allocator = std.mem.Allocator;

const convertColor = @import("../color.zig").convertColor;
const Image = @import("../image.zig").Image;

pub const Rgb = @import("../color.zig").Rgb(u8);

/// Quantization precision: 5 bits per channel → 32x32x32 lookup table.
pub const color_quantize_bits: u5 = 5;

/// Color histogram entry for adaptive palette generation.
pub const ColorCount = struct {
    r: u8,
    g: u8,
    b: u8,
    count: u32,
};

/// Box used by the median-cut algorithm.
pub const ColorBox = struct {
    colors: []ColorCount,
    r_min: u8,
    r_max: u8,
    g_min: u8,
    g_max: u8,
    b_min: u8,
    b_max: u8,
    population: u32,

    fn volume(self: ColorBox) u32 {
        if (self.r_max < self.r_min or self.g_max < self.g_min or self.b_max < self.b_min) {
            return 0;
        }
        const r_size = @as(u32, self.r_max) - @as(u32, self.r_min) + 1;
        const g_size = @as(u32, self.g_max) - @as(u32, self.g_min) + 1;
        const b_size = @as(u32, self.b_max) - @as(u32, self.b_min) + 1;
        return r_size * g_size * b_size;
    }

    fn largestDimension(self: ColorBox) u8 {
        const r_range = if (self.r_max >= self.r_min) self.r_max - self.r_min else 0;
        const g_range = if (self.g_max >= self.g_min) self.g_max - self.g_min else 0;
        const b_range = if (self.b_max >= self.b_min) self.b_max - self.b_min else 0;

        if (g_range >= r_range and g_range >= b_range) return 1; // green
        if (r_range >= b_range) return 0; // red
        return 2; // blue
    }
};

/// 3D lookup table mapping 5-bit-per-channel RGB → palette index.
pub const ColorLookupTable = struct {
    table: [32][32][32]u8,

    /// Creates and initializes a color lookup table for the given palette.
    pub fn init(palette: []const Rgb) ColorLookupTable {
        var self: ColorLookupTable = undefined;
        const lut_size = @as(usize, 1) << color_quantize_bits;

        // Flatten palette for SIMD processing
        var pal_r: [256]i32 = undefined;
        var pal_g: [256]i32 = undefined;
        var pal_b: [256]i32 = undefined;

        for (palette, 0..) |c, i| {
            pal_r[i] = c.r;
            pal_g[i] = c.g;
            pal_b[i] = c.b;
        }

        for (0..lut_size) |r| {
            for (0..lut_size) |g| {
                for (0..lut_size) |b| {
                    const rgb = Rgb{
                        .r = @intCast(r << (8 - color_quantize_bits) | (r >> (2 * color_quantize_bits - 8))),
                        .g = @intCast(g << (8 - color_quantize_bits) | (g >> (2 * color_quantize_bits - 8))),
                        .b = @intCast(b << (8 - color_quantize_bits) | (b >> (2 * color_quantize_bits - 8))),
                    };
                    self.table[r][g][b] = findNearestColorSIMD(palette.len, &pal_r, &pal_g, &pal_b, rgb);
                }
            }
        }
        return self;
    }

    /// Finds the nearest color in a palette to the target color using SIMD.
    fn findNearestColorSIMD(
        len: usize,
        pal_r: *const [256]i32,
        pal_g: *const [256]i32,
        pal_b: *const [256]i32,
        target: Rgb,
    ) u8 {
        const VecWidth = 16;
        const V = @Vector(VecWidth, i32);

        const tr = @as(i32, target.r);
        const tg = @as(i32, target.g);
        const tb = @as(i32, target.b);

        const v_tr: V = @splat(tr);
        const v_tg: V = @splat(tg);
        const v_tb: V = @splat(tb);

        // Track min distance and index. Pack distance (upper bits) and index (lower 8 bits) into a u32 score.
        var best_score: u32 = std.math.maxInt(u32);

        const iota: V = blk: {
            var idxs: [VecWidth]i32 = undefined;
            for (0..VecWidth) |k| idxs[k] = @intCast(k);
            break :blk idxs;
        };

        var i: usize = 0;

        while (i + VecWidth <= len) : (i += VecWidth) {
            const vr: V = pal_r[i..][0..VecWidth].*;
            const vg: V = pal_g[i..][0..VecWidth].*;
            const vb: V = pal_b[i..][0..VecWidth].*;

            const dr = vr - v_tr;
            const dg = vg - v_tg;
            const db = vb - v_tb;

            const dist = dr * dr + dg * dg + db * db;

            const indices: V = iota + @as(V, @splat(@intCast(i)));

            const score = (@as(@Vector(VecWidth, u32), @bitCast(dist)) << @as(@Vector(VecWidth, u5), @splat(8))) | @as(@Vector(VecWidth, u32), @bitCast(indices));

            const min_vec_score = @reduce(.Min, score);
            if (min_vec_score < best_score) {
                best_score = min_vec_score;
            }
        }

        while (i < len) : (i += 1) {
            const dr = pal_r[i] - tr;
            const dg = pal_g[i] - tg;
            const db = pal_b[i] - tb;
            const dist = dr * dr + dg * dg + db * db;
            const score = (@as(u32, @intCast(dist)) << 8) | @as(u32, @intCast(i));
            if (score < best_score) {
                best_score = score;
            }
        }

        return @intCast(best_score & 0xFF);
    }

    /// Looks up the palette index for the given RGB color.
    /// The color is quantized to 5-bit precision per channel before lookup.
    pub fn lookup(self: ColorLookupTable, rgb: Rgb) u8 {
        const r5 = rgb.r >> (8 - color_quantize_bits);
        const g5 = rgb.g >> (8 - color_quantize_bits);
        const b5 = rgb.b >> (8 - color_quantize_bits);
        return self.table[r5][g5][b5];
    }
};

/// Reusable histogram buffer pool for adaptive palette generation.
/// Avoids per-call allocation of the 32K-entry counts/stamps arrays.
pub const HistogramPool = struct {
    const Node = struct {
        counts: []u32,
        stamps: []u32,
        generation: u32,
        next: ?*Node = null,
    };

    pub const Handle = struct {
        counts: []u32,
        stamps: []u32,
        generation: u32,
        node: *Node,
    };

    var lock_val = std.atomic.Value(u32).init(0);
    var available: ?*Node = null;

    pub fn acquire() !Handle {
        while (lock_val.swap(1, .acquire) != 0) {
            std.Thread.yield() catch |err| std.debug.panic("Thread.yield failed: {s}", .{@errorName(err)});
        }
        if (available) |node| {
            available = node.next;
            lock_val.store(0, .release);

            node.generation +%= 1;
            if (node.generation == 0) {
                @memset(node.stamps, 0);
                node.generation = 1;
            }

            return .{
                .counts = node.counts,
                .stamps = node.stamps,
                .generation = node.generation,
                .node = node,
            };
        }
        lock_val.store(0, .release);

        const allocator = std.heap.page_allocator;
        const required_len: usize = @as(usize, 1) << (3 * color_quantize_bits);

        const counts = try allocator.alloc(u32, required_len);
        errdefer allocator.free(counts);
        const stamps = try allocator.alloc(u32, required_len);
        errdefer allocator.free(stamps);
        @memset(stamps, 0);

        const node = try allocator.create(Node);
        node.* = .{
            .counts = counts,
            .stamps = stamps,
            .generation = 1,
            .next = null,
        };

        return .{
            .counts = node.counts,
            .stamps = node.stamps,
            .generation = node.generation,
            .node = node,
        };
    }

    pub fn release(handle: Handle) void {
        while (lock_val.swap(1, .acquire) != 0) {
            std.Thread.yield() catch |err| std.debug.panic("Thread.yield failed: {s}", .{@errorName(err)});
        }
        handle.node.next = available;
        available = handle.node;
        lock_val.store(0, .release);
    }
};

/// Generates an adaptive palette using the median-cut algorithm.
/// Writes up to `max_colors` (and at most `palette.len`) entries into `palette`,
/// returning the actual count written.
pub fn medianCut(
    comptime T: type,
    gpa: Allocator,
    image: Image(T),
    palette: []Rgb,
    max_colors: u16,
) !usize {
    var color_list: std.ArrayList(ColorCount) = .empty;
    defer color_list.deinit(gpa);

    var touched_indices = try std.ArrayList(u16).initCapacity(gpa, 1024);
    defer touched_indices.deinit(gpa);

    const histogram_len = @as(usize, 1) << (3 * color_quantize_bits);
    const hist_handle_result = HistogramPool.acquire();

    if (hist_handle_result) |hist_handle| {
        defer HistogramPool.release(hist_handle);

        if (image.stride == image.cols) {
            for (image.data) |pixel| {
                const rgb = convertColor(Rgb, pixel);

                const r5 = rgb.r >> (8 - color_quantize_bits);
                const g5 = rgb.g >> (8 - color_quantize_bits);
                const b5 = rgb.b >> (8 - color_quantize_bits);
                const key = (@as(u16, r5) << (2 * color_quantize_bits)) | (@as(u16, g5) << color_quantize_bits) | @as(u16, b5);
                const hist_index: usize = @intCast(key);

                if (hist_handle.stamps[hist_index] != hist_handle.generation) {
                    hist_handle.stamps[hist_index] = hist_handle.generation;
                    hist_handle.counts[hist_index] = 0;
                    try touched_indices.append(gpa, @intCast(hist_index));
                }
                hist_handle.counts[hist_index] += 1;
            }
        } else {
            for (0..image.rows) |r| {
                for (0..image.cols) |c| {
                    const pixel = image.at(r, c).*;
                    const rgb = convertColor(Rgb, pixel);

                    const r5 = rgb.r >> (8 - color_quantize_bits);
                    const g5 = rgb.g >> (8 - color_quantize_bits);
                    const b5 = rgb.b >> (8 - color_quantize_bits);
                    const key = (@as(u16, r5) << (2 * color_quantize_bits)) | (@as(u16, g5) << color_quantize_bits) | @as(u16, b5);
                    const hist_index: usize = @intCast(key);

                    if (hist_handle.stamps[hist_index] != hist_handle.generation) {
                        hist_handle.stamps[hist_index] = hist_handle.generation;
                        hist_handle.counts[hist_index] = 0;
                        try touched_indices.append(gpa, @intCast(hist_index));
                    }
                    hist_handle.counts[hist_index] += 1;
                }
            }
        }

        try color_list.ensureTotalCapacityPrecise(gpa, touched_indices.items.len);
        for (touched_indices.items) |key_u16| {
            const key = @as(usize, key_u16);
            const count = hist_handle.counts[key];
            if (count == 0) continue;

            const r5: u8 = @intCast((key >> (2 * color_quantize_bits)) & 0x1F);
            const g5: u8 = @intCast((key >> color_quantize_bits) & 0x1F);
            const b5: u8 = @intCast(key & 0x1F);

            const r8 = (r5 << (8 - color_quantize_bits)) | (r5 >> (2 * color_quantize_bits - 8));
            const g8 = (g5 << (8 - color_quantize_bits)) | (g5 >> (2 * color_quantize_bits - 8));
            const b8 = (b5 << (8 - color_quantize_bits)) | (b5 >> (2 * color_quantize_bits - 8));

            color_list.appendAssumeCapacity(.{
                .r = r8,
                .g = g8,
                .b = b8,
                .count = count,
            });
        }
    } else |_| {
        var counts = try gpa.alloc(u32, histogram_len);
        defer gpa.free(counts);
        @memset(counts[0..histogram_len], 0);

        for (0..image.rows) |r| {
            for (0..image.cols) |c| {
                const pixel = image.at(r, c).*;
                const rgb = convertColor(Rgb, pixel);

                const r5 = rgb.r >> (8 - color_quantize_bits);
                const g5 = rgb.g >> (8 - color_quantize_bits);
                const b5 = rgb.b >> (8 - color_quantize_bits);
                const key = (@as(u16, r5) << (2 * color_quantize_bits)) | (@as(u16, g5) << color_quantize_bits) | @as(u16, b5);
                const hist_index: usize = @intCast(key);
                counts[hist_index] += 1;
            }
        }

        for (counts, 0..) |count, key_idx| {
            if (count == 0) continue;

            const key: u32 = @intCast(key_idx);
            const r5: u8 = @intCast((key >> (2 * color_quantize_bits)) & 0x1F);
            const g5: u8 = @intCast((key >> color_quantize_bits) & 0x1F);
            const b5: u8 = @intCast(key & 0x1F);

            const r8 = (r5 << (8 - color_quantize_bits)) | (r5 >> (2 * color_quantize_bits - 8));
            const g8 = (g5 << (8 - color_quantize_bits)) | (g5 >> (2 * color_quantize_bits - 8));
            const b8 = (b5 << (8 - color_quantize_bits)) | (b5 >> (2 * color_quantize_bits - 8));

            try color_list.append(gpa, .{
                .r = r8,
                .g = g8,
                .b = b8,
                .count = count,
            });
        }
    }

    const palette_size = @min(@min(color_list.items.len, max_colors), palette.len);

    if (palette_size == 0) {
        return error.NoPaletteColors;
    }

    if (color_list.items.len == 1) {
        palette[0] = .{
            .r = color_list.items[0].r,
            .g = color_list.items[0].g,
            .b = color_list.items[0].b,
        };
        return 1;
    }

    var boxes: std.ArrayList(ColorBox) = .empty;
    defer boxes.deinit(gpa);

    var initial_box = ColorBox{
        .colors = color_list.items,
        .r_min = 255,
        .r_max = 0,
        .g_min = 255,
        .g_max = 0,
        .b_min = 255,
        .b_max = 0,
        .population = 0,
    };

    for (color_list.items) |c| {
        initial_box.r_min = @min(initial_box.r_min, c.r);
        initial_box.r_max = @max(initial_box.r_max, c.r);
        initial_box.g_min = @min(initial_box.g_min, c.g);
        initial_box.g_max = @max(initial_box.g_max, c.g);
        initial_box.b_min = @min(initial_box.b_min, c.b);
        initial_box.b_max = @max(initial_box.b_max, c.b);
        initial_box.population += c.count;
    }

    try boxes.append(gpa, initial_box);

    while (boxes.items.len < palette_size) {
        var largest_idx: ?usize = null;
        var largest_score: u64 = 0;

        for (boxes.items, 0..) |box, i| {
            if (box.colors.len <= 1) continue;
            if (box.r_max <= box.r_min and box.g_max <= box.g_min and box.b_max <= box.b_min) continue;

            const score = @as(u64, box.volume()) * @as(u64, box.population);
            if (score > largest_score) {
                largest_score = score;
                largest_idx = i;
            }
        }

        if (largest_idx == null) break;

        var box_to_split = boxes.orderedRemove(largest_idx.?);

        const dim = box_to_split.largestDimension();

        const SortContext = struct {
            dim: u8,
            pub fn lessThan(ctx: @This(), a: ColorCount, b: ColorCount) bool {
                return switch (ctx.dim) {
                    0 => a.r < b.r,
                    1 => a.g < b.g,
                    else => a.b < b.b,
                };
            }
        };

        std.sort.heap(ColorCount, box_to_split.colors, SortContext{ .dim = dim }, SortContext.lessThan);

        var total_weight: u64 = 0;
        for (box_to_split.colors) |c| {
            total_weight += c.count;
        }

        const half_weight = total_weight / 2;
        var accumulated_weight: u64 = 0;
        var cut_point: usize = 0;

        for (box_to_split.colors, 0..) |c, i| {
            accumulated_weight += c.count;
            if (accumulated_weight >= half_weight) {
                cut_point = @max(1, @min(i + 1, box_to_split.colors.len - 1));
                break;
            }
        }

        var box1 = ColorBox{
            .colors = box_to_split.colors[0..cut_point],
            .r_min = 255,
            .r_max = 0,
            .g_min = 255,
            .g_max = 0,
            .b_min = 255,
            .b_max = 0,
            .population = 0,
        };

        var box2 = ColorBox{
            .colors = box_to_split.colors[cut_point..],
            .r_min = 255,
            .r_max = 0,
            .g_min = 255,
            .g_max = 0,
            .b_min = 255,
            .b_max = 0,
            .population = 0,
        };

        for (box1.colors) |c| {
            box1.r_min = @min(box1.r_min, c.r);
            box1.r_max = @max(box1.r_max, c.r);
            box1.g_min = @min(box1.g_min, c.g);
            box1.g_max = @max(box1.g_max, c.g);
            box1.b_min = @min(box1.b_min, c.b);
            box1.b_max = @max(box1.b_max, c.b);
            box1.population += c.count;
        }

        for (box2.colors) |c| {
            box2.r_min = @min(box2.r_min, c.r);
            box2.r_max = @max(box2.r_max, c.r);
            box2.g_min = @min(box2.g_min, c.g);
            box2.g_max = @max(box2.g_max, c.g);
            box2.b_min = @min(box2.b_min, c.b);
            box2.b_max = @max(box2.b_max, c.b);
            box2.population += c.count;
        }

        if (box1.colors.len > 0 and box1.r_max >= box1.r_min) {
            try boxes.append(gpa, box1);
        }

        if (box2.colors.len > 0 and box2.r_max >= box2.r_min) {
            try boxes.append(gpa, box2);
        }
    }

    const actual_size = @min(boxes.items.len, palette.len);
    for (boxes.items[0..actual_size], 0..) |box, i| {
        var r_sum: u64 = 0;
        var g_sum: u64 = 0;
        var b_sum: u64 = 0;
        var weight_sum: u64 = 0;

        for (box.colors) |c| {
            r_sum += @as(u64, c.r) * @as(u64, c.count);
            g_sum += @as(u64, c.g) * @as(u64, c.count);
            b_sum += @as(u64, c.b) * @as(u64, c.count);
            weight_sum += c.count;
        }

        if (weight_sum > 0) {
            palette[i] = .{
                .r = @intCast(@divTrunc(r_sum, weight_sum)),
                .g = @intCast(@divTrunc(g_sum, weight_sum)),
                .b = @intCast(@divTrunc(b_sum, weight_sum)),
            };
        } else {
            palette[i] = .{
                .r = (box.r_min + box.r_max) / 2,
                .g = (box.g_min + box.g_max) / 2,
                .b = (box.b_min + box.b_max) / 2,
            };
        }
    }

    return actual_size;
}

/// Generates the fixed 6x7x6 palette (252 colors) into the given buffer.
pub fn fixed6x7x6Palette(palette: []Rgb) void {
    var idx: usize = 0;
    for (0..6) |r| {
        for (0..7) |g| {
            for (0..6) |b| {
                palette[idx] = Rgb{
                    .r = @intCast((r * 255 + 2) / 5),
                    .g = @intCast((g * 255 + 3) / 6),
                    .b = @intCast((b * 255 + 2) / 5),
                };
                idx += 1;
            }
        }
    }
}

/// Generates the web-safe 216-color palette (6x6x6 RGB cube) into the given buffer.
pub fn web216Palette(palette: []Rgb) void {
    var idx: usize = 0;
    for (0..6) |r| {
        for (0..6) |g| {
            for (0..6) |b| {
                palette[idx] = Rgb{
                    .r = @intCast(r * 51),
                    .g = @intCast(g * 51),
                    .b = @intCast(b * 51),
                };
                idx += 1;
            }
        }
    }
}

/// Standard VGA 16-color palette.
pub const vga16_palette = [16]Rgb{
    Rgb{ .r = 0, .g = 0, .b = 0 }, // Black
    Rgb{ .r = 128, .g = 0, .b = 0 }, // Maroon
    Rgb{ .r = 0, .g = 128, .b = 0 }, // Green
    Rgb{ .r = 128, .g = 128, .b = 0 }, // Olive
    Rgb{ .r = 0, .g = 0, .b = 128 }, // Navy
    Rgb{ .r = 128, .g = 0, .b = 128 }, // Purple
    Rgb{ .r = 0, .g = 128, .b = 128 }, // Teal
    Rgb{ .r = 192, .g = 192, .b = 192 }, // Silver
    Rgb{ .r = 128, .g = 128, .b = 128 }, // Gray
    Rgb{ .r = 255, .g = 0, .b = 0 }, // Red
    Rgb{ .r = 0, .g = 255, .b = 0 }, // Lime
    Rgb{ .r = 255, .g = 255, .b = 0 }, // Yellow
    Rgb{ .r = 0, .g = 0, .b = 255 }, // Blue
    Rgb{ .r = 255, .g = 0, .b = 255 }, // Fuchsia
    Rgb{ .r = 0, .g = 255, .b = 255 }, // Cyan
    Rgb{ .r = 255, .g = 255, .b = 255 }, // White
};

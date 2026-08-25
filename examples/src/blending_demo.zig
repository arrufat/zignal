const std = @import("std");
const Io = std.Io;

const zignal = @import("zignal");
const Canvas = zignal.Canvas;
const Image = zignal.Image;
const Point = zignal.Point;
const Blending = zignal.Blending;

const Rgba = zignal.Rgba(u8);

// Every blend mode except .none (a raw overwrite, nothing to demonstrate).
const blend_modes = std.enums.values(Blending)[1..];

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const io = Io.Threaded.global_single_threaded.io();

    const tile = 128;
    const grid_cols = 4;
    const grid_rows = (blend_modes.len + grid_cols - 1) / grid_cols;
    const cols: u32 = grid_cols * tile;
    const rows: u32 = grid_rows * tile;

    var image: Image(Rgba) = try .init(allocator, rows, cols);
    const canvas: Canvas(Rgba) = .init(allocator, image);

    // Background: horizontal hue sweep, computed once and copied to every row.
    for (0..cols) |c| {
        const hue = 360.0 * @as(f32, @floatFromInt(c % tile)) / tile;
        const hsv: zignal.Hsv(f32) = .{ .h = hue, .s = 60, .v = 80 };
        image.at(0, c).* = zignal.convertColor(Rgba, hsv);
    }
    for (1..rows) |r| {
        @memcpy(image.data[r * image.stride ..][0..cols], image.data[0..cols]);
    }

    const font = zignal.font.font8x8.basic;
    // Channels on both sides of 0.5, so no blend mode degenerates (as 50% gray does).
    const orange: Rgba = .{ .r = 255, .g = 128, .b = 0, .a = 255 };
    const translucent_white: Rgba = .{ .r = 255, .g = 255, .b = 255, .a = 160 };

    for (blend_modes, 0..) |blending, i| {
        const gx = @as(f32, @floatFromInt(i % grid_cols)) * tile;
        const gy = @as(f32, @floatFromInt(i / grid_cols)) * tile;
        const center: Point(2, f32) = .init(.{ gx + tile / 2, gy + tile / 2 });

        const opts: zignal.DrawOptions = .{ .mode = .soft, .blending = blending };
        canvas.fillCircle(center, tile * 0.32, orange, opts);
        canvas.drawCircle(center, tile * 0.40, translucent_white, 3, opts);

        try canvas.drawText(@tagName(blending), .init(.{ gx + 6, gy + 6 }), Rgba.white, .{ .bitmap = font }, null, .soft);
    }

    try image.save(io, allocator, "blending_demo.png");
    std.debug.print("Saved blending_demo.png ({d} blend modes)\n", .{blend_modes.len});
}

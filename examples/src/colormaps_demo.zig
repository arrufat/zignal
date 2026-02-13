const std = @import("std");
const Io = std.Io;

const zignal = @import("zignal");
const Image = zignal.Image;

const Rgb = zignal.Rgb(u8);
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Setup IO context
    const io = Io.Threaded.global_single_threaded.ioBasic();

    const cols = 512;
    const rows = 512;

    std.debug.print("Generating test pattern ({d}x{d})...\n", .{ cols, rows });

    // Create a grayscale image with a pattern
    var gray: Image(u8) = try .init(allocator, rows, cols);
    defer gray.deinit(allocator);

    for (0..rows) |r| {
        for (0..cols) |c| {
            const fx = @as(f32, @floatFromInt(c)) / @as(f32, @floatFromInt(cols));
            const fy = @as(f32, @floatFromInt(r)) / @as(f32, @floatFromInt(rows));
            const cx = fx - 0.5;
            const cy = fy - 0.5;
            const dist = @sqrt(cx * cx + cy * cy);
            const val = 0.5 + 0.5 * std.math.sin(dist * 30.0 + std.math.atan2(cy, cx) * 5.0);
            gray.at(r, c).* = zignal.convertColor(u8, val);
        }
    }
    try gray.save(io, allocator, "grayscale.png");

    // Apply and save colormaps
    const maps = [_]struct { name: []const u8, map: zignal.Colormap }{
        .{ .name = "colormap_jet.png", .map = .{ .jet = .{} } },
        .{ .name = "colormap_heat.png", .map = .{ .heat = .{} } },
        .{ .name = "colormap_turbo.png", .map = .{ .turbo = .{} } },
        .{ .name = "colormap_viridis.png", .map = .{ .viridis = .{} } },
    };

    for (maps) |entry| {
        std.debug.print("Applying colormap: {s}...\n", .{entry.name});
        var colored = try gray.applyColormap(allocator, entry.map);
        defer colored.deinit(allocator);
        try colored.save(io, allocator, entry.name);
    }

    std.debug.print("Done! Generated 4 images.\n", .{});
}

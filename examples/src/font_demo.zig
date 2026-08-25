//! Renders a type specimen with any supported font (BDF, PCF, TrueType, optionally
//! gzipped), detected from the file: `font_demo [font-path]`. Without an argument
//! it tries a few system TrueType fonts and falls back to the built-in 8x8 font.

const std = @import("std");

const zignal = @import("zignal");

const Image = zignal.Image;
const Rgb = zignal.Rgb(u8);
const Canvas = zignal.Canvas;
const Font = zignal.Font;
const p = zignal.Point(2, f32).init;

const system_fonts = [_][]const u8{
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/TTF/Roboto-Regular.ttf",
    "/Library/Fonts/Arial.ttf",
    "C:\\Windows\\Fonts\\arial.ttf",
};

const sample = "The quick brown fox jumps over the lazy dog";
const kerning_pairs = "AVAWATo LTYa f. 1234567890";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip();

    var loaded: ?Font = if (args.next()) |path|
        try Font.load(io, gpa, path)
    else for (system_fonts) |path| {
        break Font.load(io, gpa, path) catch continue;
    } else null;
    defer if (loaded) |*f| f.deinit(gpa);
    const font: Font = loaded orelse .{ .bitmap = zignal.font.font8x8.basic };

    switch (font) {
        .bitmap => |b| std.debug.print("bitmap font {f}\n", .{b}),
        .vector => |v| std.debug.print("{f}\n", .{v}),
    }

    const sizes = [_]f32{ 12, 16, 24, 36, 56 };
    var height: f32 = 16;
    for (sizes) |size| height += font.lineHeight(size) + 6;
    height += 2 * font.lineHeight(24) + 16;

    var image: Image(Rgb) = try .init(gpa, @ceil(height), 1000);
    defer image.deinit(gpa);
    image.fill(.{ .r = 255, .g = 255, .b = 255 });
    const canvas: Canvas(Rgb) = .init(gpa, image);
    const ink: Rgb = .{ .r = 24, .g = 24, .b = 24 };
    const accent: Rgb = .{ .r = 190, .g = 40, .b = 40 };

    var y: f32 = 8;
    var last_top: f32 = y;
    for (sizes) |size| {
        last_top = y;
        try canvas.drawText(sample, p(.{ 8, y }), ink, font, size, .soft);
        y += font.lineHeight(size) + 6;
    }
    // Same text antialiased and aliased, with kerning pairs that show pair adjustment.
    try canvas.drawText(kerning_pairs, p(.{ 8, y }), accent, font, 24, .soft);
    y += font.lineHeight(24) + 4;
    try canvas.drawText(kerning_pairs, p(.{ 8, y }), accent, font, 24, .fast);

    // Underline the widest line using the measured bounds.
    const bounds = font.getTextBounds(sample, sizes[sizes.len - 1]);
    const baseline = last_top + font.ascent(sizes[sizes.len - 1]);
    canvas.drawLine(p(.{ 8, baseline + 4 }), p(.{ 8 + bounds.r, baseline + 4 }), accent, 1, .soft);

    try image.save(io, gpa, "font_demo.png");
    std.debug.print("{f}\n", .{image.display(io, .{ .auto = .{} })});
}

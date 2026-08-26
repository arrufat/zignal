//! Renders a type specimen with any supported font (BDF, PCF, TrueType, CFF OpenType,
//! collections, optionally gzipped), detected from the file: `font_demo [font-path]`.
//! Without an argument it tries a few system fonts and falls back to the built-in 8x8 font.
//! Below the size ladder it shows the layout features: a wrapped, centered paragraph in
//! a box, right-aligned lines with tight tracking, and outlined text.

const std = @import("std");

const zignal = @import("zignal");

const Image = zignal.Image;
const Rgb = zignal.Rgb(u8);
const Canvas = zignal.Canvas;
const Font = zignal.Font;
const Rectangle = zignal.Rectangle(f32);
const p = zignal.Point(2, f32).init;

const system_fonts = [_][]const u8{
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/TTF/Roboto-Regular.ttf",
    "/usr/share/fonts/gnu-free/FreeSans.otf",
    "/usr/share/fonts/opentype/freefont/FreeSans.otf",
    "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
    "/Library/Fonts/Arial.ttf",
    "C:\\Windows\\Fonts\\arial.ttf",
};

const sample = "The quick brown fox jumps over the lazy dog";
const kerning_pairs = "AVAWATo LTYa f. 1234567890";
const paragraph = "Text boxes wrap at spaces, align each line and place the whole block, " ++
    "so a caption can be centered in its frame without measuring anything by hand.";

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
    // Cache parsed glyphs and rasterized masks; the copy below shares the cache.
    if (loaded) |*f| try f.enableCache(gpa);
    const font: Font = loaded orelse .{ .bitmap = zignal.font.font8x8.basic };

    switch (font) {
        .bitmap => |b| std.debug.print("bitmap font {f}\n", .{b}),
        .vector => |v| std.debug.print("{f}\n", .{v}),
    }

    const sizes = [_]f32{ 12, 16, 24, 36, 56 };
    var height: f32 = 16;
    for (sizes) |size| height += font.lineHeight(size) + 6;
    height += 2 * font.lineHeight(24) + 16;
    const box_height = 4.5 * font.lineHeight(20);
    height += box_height + font.lineHeight(48) + 32;

    var image: Image(Rgb) = try .init(gpa, @ceil(height), 1000);
    defer image.deinit(gpa);
    const paper: Rgb = .{ .r = 255, .g = 255, .b = 255 };
    image.fill(paper);
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
    y += font.lineHeight(24) + 16;

    // A wrapped paragraph centered in its box, next to right-aligned lines with tight
    // tracking anchored at the box's bottom.
    const frame: Rgb = .{ .r = 120, .g = 140, .b = 200 };
    const left: Rectangle = .{ .l = 8, .t = y, .r = 600, .b = y + box_height };
    canvas.drawRectangle(left, frame, 1, .soft);
    try canvas.drawTextBox(paragraph, left.shrink(8), ink, font, 20, .{ .wrap = true, .halign = .center, .valign = .middle, .line_spacing = 1.15 }, .soft);
    const right: Rectangle = .{ .l = 612, .t = y, .r = 992, .b = y + box_height };
    canvas.drawRectangle(right, frame, 1, .soft);
    try canvas.drawTextBox("right aligned\nbottom anchored\ntight tracking", right.shrink(8), ink, font, 20, .{ .halign = .right, .valign = .bottom, .letter_spacing = -1 }, .soft);
    y += box_height + 12;

    // Outlined text: a stroke under a fill, then a hollow stroke on its own. Bitmap fonts
    // get a halo instead of an outline.
    const outline: Rgb = .{ .r = 30, .g = 80, .b = 180 };
    try canvas.drawTextOutline("Outlined", p(.{ 8, y }), outline, font, 48, 5, .soft);
    try canvas.drawText("Outlined", p(.{ 8, y }), paper, font, 48, .soft);
    const measured = font.measureText("Outlined", 48, null, .default);
    try canvas.drawTextOutline("& hollow", p(.{ 8 + measured.r + 24, y }), accent, font, 48, 2, .soft);

    try image.save(io, gpa, "font_demo.png");
    std.debug.print("{f}\n", .{image.display(io, .{ .auto = .{} })});
}

//! Info subcommand: inspects and displays image and font metadata and format details.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");
const png = zignal.png;
const jpeg = zignal.jpeg;
const bmp = zignal.bmp;
const gif = zignal.gif;
const jxl = zignal.jxl;
const webp = zignal.webp;

const args = @import("args.zig");
const common = @import("common.zig");

const Args = struct {
    stats: bool = false,

    pub const meta = .{
        .stats = .{ .help = "Compute and display image statistics (min, max, mean, stdDev); ignored for fonts" },
    };
};

pub const description = "Display detailed information about one or more image or font files.";

pub const help = args.generateHelp(
    Args,
    "zignal info [options] <file1> <file2> ...",
    description,
);

pub fn run(io: Io, writer: *Io.Writer, gpa: Allocator, iterator: *std.process.Args.Iterator) !void {
    const parsed = try args.parse(Args, gpa, iterator);
    defer parsed.deinit(gpa);

    if (parsed.help or parsed.positionals.len == 0) {
        try args.printHelp(writer, help);
        return;
    }

    var read_buffer: [4096]u8 = undefined;
    var failed = false;

    for (parsed.positionals) |path| {
        if (parsed.positionals.len > 1) {
            try writer.print("File: {s}\n", .{path});
        }

        const result = blk: {
            std.log.debug("inspecting: {s}", .{path});
            const file = Io.Dir.cwd().openFile(io, path, .{}) catch |err| break :blk err;
            defer file.close(io);

            var reader = file.reader(io, &read_buffer);
            const image_format = zignal.image.Format.peek(&reader.interface) catch |err| switch (err) {
                error.UnsupportedImageFormat => break :blk printFontInfo(io, writer, gpa, path),
                else => break :blk err,
            };
            std.log.debug("format detected: {s}", .{@tagName(image_format)});

            switch (image_format) {
                .png => {
                    const info = png.getInfo(&reader.interface, .{}) catch |err| break :blk err;

                    try writer.print("Format:      PNG\n", .{});
                    try writer.print("Dimensions:  {d}x{d}\n", .{ info.width, info.height });
                    try writer.print("Bit Depth:   {d}\n", .{info.bit_depth});
                    try writer.print("Channels:    {d}\n", .{info.channels()});
                    try writer.print("Color Space: {s}\n", .{@tagName(info.color_type)});

                    if (info.gamma) |g| {
                        try writer.print("Gamma:       {d}\n", .{g});
                    }
                    if (info.srgb_intent) |intent| {
                        try writer.print("sRGB:        {s}\n", .{@tagName(intent)});
                    }
                },
                .jpeg => {
                    const info = jpeg.getInfo(&reader.interface, .{}) catch |err| break :blk err;

                    try writer.print("Format:      JPEG\n", .{});
                    try writer.print("Dimensions:  {d}x{d}\n", .{ info.width, info.height });
                    try writer.print("Bit Depth:   {d}\n", .{info.precision});
                    try writer.print("Channels:    {d}\n", .{info.num_components});
                    try writer.print("Color Space: {s}\n", .{if (info.num_components == 1) "Grayscale" else "YCbCr"});
                    try writer.print("Frame Type:  {s}\n", .{@tagName(info.frame_type)});
                },
                .bmp => {
                    const info = bmp.getInfo(&reader.interface, .{}) catch |err| break :blk err;

                    try writer.print("Format:      BMP\n", .{});
                    try writer.print("Dimensions:  {d}x{d}\n", .{ info.width, info.height });
                    try writer.print("Bit Depth:   {d}\n", .{info.bit_depth});
                    try writer.print("Compression: {s}\n", .{@tagName(info.compression)});
                    try writer.print("DIB Header:  {s}\n", .{@tagName(info.dib_header)});
                    try writer.print("Top-down:    {s}\n", .{if (info.top_down) "yes" else "no"});
                    if (info.palette_entries > 0) {
                        try writer.print("Palette:     {d} entries\n", .{info.palette_entries});
                    }
                    if (info.hasAlpha()) {
                        try writer.print("Alpha:       yes\n", .{});
                    }
                },
                .gif => {
                    const info = gif.getInfo(&reader.interface, .{}) catch |err| break :blk err;

                    try writer.print("Format:      GIF\n", .{});
                    try writer.print("Version:     {s}\n", .{@tagName(info.version)});
                    try writer.print("Dimensions:  {d}x{d}\n", .{ info.width, info.height });
                    try writer.print("Frames:      {d}\n", .{info.frame_count});
                    if (info.loop_count == 0) {
                        try writer.print("Loop count:  infinite\n", .{});
                    } else {
                        try writer.print("Loop count:  {d}\n", .{info.loop_count});
                    }
                    if (info.has_global_color_table) {
                        try writer.print("Palette:     {d} entries (global)\n", .{info.global_color_table_size});
                    }
                },
                .jxl => {
                    const info = jxl.getInfo(&reader.interface, .{}) catch |err| break :blk err;

                    try writer.print("Format:      JPEG XL\n", .{});
                    try writer.print("Dimensions:  {d}x{d}\n", .{ info.width, info.height });
                    try writer.print("Bit Depth:   {d}{s}\n", .{ info.bits_per_sample, if (info.exponent_bits_per_sample > 0) " (float)" else "" });
                    try writer.print("Channels:    {d}\n", .{info.num_color_channels + @intFromBool(info.has_alpha)});
                    try writer.print("Encoding:    {s}\n", .{if (info.uses_original_profile) "original color space" else "XYB"});
                    if (info.has_animation) {
                        try writer.print("Animated:    yes\n", .{});
                    }
                },
                .webp => {
                    const info = webp.getInfo(&reader.interface, .{}) catch |err| break :blk err;

                    try writer.print("Format:      WebP\n", .{});
                    try writer.print("Dimensions:  {d}x{d}\n", .{ info.width, info.height });
                    try writer.print("Encoding:    {s}\n", .{@tagName(info.format)});
                    try writer.print("Alpha:       {s}\n", .{if (info.has_alpha) "yes" else "no"});
                    if (info.has_animation) {
                        try writer.print("Animated:    yes\n", .{});
                    }
                },
            }

            if (parsed.options.stats) {
                std.log.debug("loading image for stats: {s}", .{path});
                var image = zignal.Image(zignal.Rgba(u8)).load(io, gpa, path) catch |err| break :blk err;
                defer image.deinit(gpa);

                const timer = common.Timer.begin(io);
                var r_stats: zignal.stats.Running(f64, .summary) = .init();
                var g_stats: zignal.stats.Running(f64, .summary) = .init();
                var b_stats: zignal.stats.Running(f64, .summary) = .init();

                for (image.data) |pixel| {
                    r_stats.add(pixel.r);
                    g_stats.add(pixel.g);
                    b_stats.add(pixel.b);
                }
                timer.logElapsed("statistics");

                try writer.print("\n{s: <8} {s: >8} {s: >8} {s: >10} {s: >10}\n", .{ "Channel", "Min", "Max", "Mean", "StdDev" });
                inline for (.{ .{ "Red", &r_stats }, .{ "Green", &g_stats }, .{ "Blue", &b_stats } }) |entry| {
                    try writer.print("{s: <8} {d: >8} {d: >8} {d: >10.2} {d: >10.2}\n", .{
                        entry[0],
                        entry[1].min(),
                        entry[1].max(),
                        entry[1].mean(),
                        entry[1].stdDev(),
                    });
                }
            }
            break :blk {};
        };

        if (result) |_| {} else |err| {
            std.log.err("failed to get info for '{s}': {t}", .{ path, err });
            failed = true;
        }

        if (parsed.positionals.len > 1) {
            try writer.print("\n", .{});
        }
    }
    try writer.flush();
    if (failed) return error.BatchIncomplete;
}

fn printFontInfo(io: Io, writer: *Io.Writer, gpa: Allocator, path: []const u8) !void {
    const format = try zignal.font.Format.detectFromPath(io, path) orelse return error.UnsupportedFormat;
    std.log.debug("format detected: {s}", .{@tagName(format)});
    var font: zignal.Font = try .load(io, gpa, path);
    defer font.deinit(gpa);

    try writer.print("Format:      {s}\n", .{switch (format) {
        .bdf => "BDF",
        .pcf => "PCF",
        .ttf => "TrueType",
        .otf => "OpenType",
        .ttc => "OpenType collection",
    }});
    switch (font) {
        .bitmap => |b| {
            try writer.print("Name:        {s}\n", .{b.name});
            try writer.print("Cell Size:   {d}x{d}\n", .{ b.char_width, b.char_height });
            try writer.print("Ascent:      {d}\n", .{b.ascent()});
            try writer.print("Glyphs:      {d}\n", .{b.glyphCount()});
            try writer.print("Spacing:     {s}\n", .{if (b.isMonospace()) "monospace" else "proportional"});
        },
        .vector => |v| {
            if (format == .ttc) {
                try writer.print("Faces:       {d} (showing face 0)\n", .{v.num_faces});
            }
            try writer.print("Outlines:    {s}\n", .{switch (v.tables.outlines) {
                .glyf => "glyf (quadratic)",
                .cff => "CFF (cubic)",
            }});
            try writer.print("Units/em:    {d}\n", .{v.units_per_em});
            try writer.print("Glyphs:      {d}\n", .{v.num_glyphs});
            try writer.print("Ascent:      {d}\n", .{v.ascent});
            try writer.print("Descent:     {d}\n", .{v.descent});
            try writer.print("Line Gap:    {d}\n", .{v.line_gap});
            const gpos = v.tables.gpos != null;
            const kern = v.tables.kern != null;
            try writer.print("Kerning:     {s}\n", .{if (gpos and kern) "GPOS, kern" else if (gpos) "GPOS" else if (kern) "kern" else "none"});
        },
    }
}

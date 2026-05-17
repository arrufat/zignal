//! Terminal display formatting for images

const std = @import("std");
const Io = std.Io;

const color = @import("../color.zig");
const Image = @import("../image.zig").Image;
const Interpolation = @import("interpolation.zig").Interpolation;
const kitty = @import("../kitty.zig");
const sixel = @import("../sixel.zig");
const terminal = @import("../terminal.zig");

/// Display format options
pub const DisplayFormat = union(enum) {
    /// Automatically detect the best format (kitty -> sixel -> sgr)
    auto: struct {
        /// Optional target width in pixels
        width: ?u32 = null,
        /// Optional target height in pixels
        height: ?u32 = null,
        /// Interpolation method for scaling
        interpolation: ?Interpolation = null,
        pub const default: @This() = .{};
    },
    /// Kitty graphics protocol with options
    kitty: kitty.Options,
    /// Force sixel output with specific options
    sixel: sixel.Options,
    /// SGR (Select Graphic Rendition) with Unicode half-block characters for 2x vertical resolution
    /// Requires a monospace font with Unicode block element support (U+2580)
    sgr: struct {
        /// Optional target width in pixels
        width: ?u32 = null,
        /// Optional target height in pixels
        height: ?u32 = null,
        pub const default: @This() = .{};
    },
    /// Braille patterns for 2x4 monochrome resolution
    /// Requires Unicode Braille pattern support (U+2800-U+28FF)
    /// Color images are binarized with threshold
    braille: struct {
        /// Brightness threshold for on/off (0.0-1.0)
        threshold: f32 = 0.5,
        /// Optional target width in pixels
        width: ?u32 = null,
        /// Optional target height in pixels
        height: ?u32 = null,
        pub const default: @This() = .{};
    },

    /// Sets the target width and height on the active variant. Every variant
    /// carries these fields, so this works uniformly.
    pub fn setSize(self: *DisplayFormat, w: ?u32, h: ?u32) void {
        switch (self.*) {
            inline else => |*opts| {
                opts.width = w;
                opts.height = h;
            },
        }
    }

    /// Sets the interpolation method on variants that scale images
    /// (`kitty`, `sixel`, `auto`). No-op for `sgr` and `braille`, which do
    /// not resample.
    pub fn setInterpolation(self: *DisplayFormat, interp: Interpolation) void {
        switch (self.*) {
            inline .kitty, .sixel, .auto => |*opts| opts.interpolation = interp,
            .sgr, .braille => {},
        }
    }
};

/// Formatter struct for terminal display with progressive degradation
pub fn DisplayFormatter(comptime T: type) type {
    return struct {
        image: *const Image(T),
        display_format: DisplayFormat,
        io: Io,

        const Self = @This();

        // Caller owns `out_scaled` lifetime via defer in its scope.
        fn maybeScale(
            self: Self,
            allocator: std.mem.Allocator,
            w: ?u32,
            h: ?u32,
            out_scaled: *?Image(T),
        ) *const Image(T) {
            const scale_factor = terminal.aspectScale(w, h, self.image.rows, self.image.cols);
            if (@abs(scale_factor - 1.0) <= 0.001) return self.image;
            out_scaled.* = self.image.scale(allocator, scale_factor, .bilinear) catch return self.image;
            return &out_scaled.*.?;
        }

        pub fn format(self: Self, writer: *Io.Writer) Io.Writer.Error!void {
            var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();

            fmt: switch (self.display_format) {
                .auto => |options| {
                    if (kitty.isSupported(self.io)) {
                        var opts: kitty.Options = .default;
                        opts.width = options.width;
                        opts.height = options.height;
                        if (options.interpolation) |interp| opts.interpolation = interp;
                        continue :fmt .{ .kitty = opts };
                    } else if (sixel.isSupported(self.io)) {
                        var opts: sixel.Options = .default;
                        opts.width = options.width;
                        opts.height = options.height;
                        if (options.interpolation) |interp| opts.interpolation = interp;
                        continue :fmt .{ .sixel = opts };
                    } else {
                        continue :fmt .{ .sgr = .{ .width = options.width, .height = options.height } };
                    }
                },
                .kitty => |options| {
                    const data = kitty.fromImage(T, self.image.*, allocator, options) catch |err| switch (err) {
                        error.OutOfMemory => kitty.fromImage(T, self.image.*, allocator, .default) catch null,
                        else => null,
                    };
                    if (data) |d| {
                        try writer.writeAll(d);
                    } else if (self.display_format == .auto) {
                        continue :fmt .{ .sgr = .{ .width = options.width, .height = options.height } };
                    } else {
                        try writer.writeAll("\x1b_Ga=d\x1b\\");
                    }
                },
                .sixel => |options| {
                    const data = sixel.fromImage(T, self.image.*, allocator, options) catch |err| switch (err) {
                        error.OutOfMemory => sixel.fromImage(T, self.image.*, allocator, .fallback) catch null,
                        else => null,
                    };
                    if (data) |d| {
                        try writer.writeAll(d);
                    } else if (self.display_format == .auto) {
                        continue :fmt .{ .sgr = .{ .width = options.width, .height = options.height } };
                    } else {
                        try writer.writeAll("\x1bPq\x1b\\");
                    }
                },
                .sgr => |options| {
                    var scaled_image: ?Image(T) = null;
                    defer if (scaled_image) |*img| img.deinit(allocator);
                    const image_to_display = self.maybeScale(allocator, options.width, options.height, &scaled_image);

                    const Rgb = color.Rgb(u8);
                    const row_pairs = (image_to_display.rows + 1) / 2;

                    for (0..row_pairs) |pair_idx| {
                        for (0..image_to_display.cols) |col| {
                            const row1 = pair_idx * 2;
                            // Odd-row image: duplicate the last row so the final half-block renders as a solid cell.
                            const row2 = if (row1 + 1 < image_to_display.rows) row1 + 1 else row1;

                            const rgb_upper = color.convertColor(Rgb, image_to_display.at(row1, col).*);
                            const rgb_lower = color.convertColor(Rgb, image_to_display.at(row2, col).*);

                            try writer.print("\x1b[38;2;{d};{d};{d};48;2;{d};{d};{d}m▀", .{
                                rgb_upper.r, rgb_upper.g, rgb_upper.b,
                                rgb_lower.r, rgb_lower.g, rgb_lower.b,
                            });
                        }
                        try writer.writeAll("\x1b[0m");
                        if (pair_idx < row_pairs - 1) try writer.writeByte('\n');
                    }
                },
                .braille => |config| {
                    var scaled_image: ?Image(T) = null;
                    defer if (scaled_image) |*img| img.deinit(allocator);
                    const image_to_display = self.maybeScale(allocator, config.width, config.height, &scaled_image);

                    // Braille dot numbering (Unicode): col0 = dots 1,2,3,7; col1 = dots 4,5,6,8.
                    const braille_bits = [4][2]u3{
                        .{ 0, 3 },
                        .{ 1, 4 },
                        .{ 2, 5 },
                        .{ 6, 7 },
                    };
                    const block_rows = (image_to_display.rows + 3) / 4;
                    const block_cols = (image_to_display.cols + 1) / 2;

                    for (0..block_rows) |block_row| {
                        for (0..block_cols) |block_col| {
                            var pattern: u8 = 0;

                            for (0..4) |dy| {
                                for (0..2) |dx| {
                                    const y = block_row * 4 + dy;
                                    const x = block_col * 2 + dx;

                                    if (y < image_to_display.rows and x < image_to_display.cols) {
                                        const brightness = color.convertColor(f32, image_to_display.at(y, x).*);
                                        if (brightness > config.threshold) {
                                            pattern |= @as(u8, 1) << braille_bits[dy][dx];
                                        }
                                    }
                                }
                            }

                            // U+2800..U+28FF encodes as 0xE2 0xA0..0xA3 0x80..0xBF in UTF-8.
                            try writer.writeAll(&[3]u8{
                                0xE2,
                                0xA0 | (pattern >> 6),
                                0x80 | (pattern & 0x3F),
                            });
                        }
                        if (block_row < block_rows - 1) try writer.writeByte('\n');
                    }
                },
            }
        }
    };
}

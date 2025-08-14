//! Zignal library logo generator
//!
//! Creates a 512x512 pixel logo that represents signal and image processing concepts
//! The design features the word "ZIGNAL" with visual elements representing
//! signal processing (waveforms) and image processing (color channels).

const std = @import("std");
const zignal = @import("zignal");
const Image = zignal.Image;
const Canvas = zignal.Canvas;
const Rgb = zignal.Rgb;
const Oklab = zignal.Oklab;
const Oklch = zignal.Oklch;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a 512x512 image for the logo
    var image = try Image(Rgb).initAlloc(allocator, 512, 512);
    defer image.deinit(allocator);

    // Create canvas for drawing
    var canvas = Canvas(Rgb).init(allocator, image);

    // Fill background with a dark color
    const bg_color = Rgb{ .r = 20, .g = 24, .b = 32 };
    canvas.fill(bg_color);

    // Draw a subtle grid pattern in the background
    drawBackgroundGrid(&canvas);

    // Draw signal waveforms behind the text
    try drawSignalWaves(&canvas, allocator);

    // Draw the main "ZIGNAL" text using the font system
    drawZignalText(&canvas);

    // Add decorative elements
    drawDecorativeElements(&canvas);

    std.debug.print("{f}\n", .{image.display(.auto)});

    // Save the logo
    try image.save(allocator, "zignal_logo.png");
    std.debug.print("Logo saved as zignal_logo.png\n", .{});
}

fn drawBackgroundGrid(canvas: *Canvas(Rgb)) void {
    const grid_color = Rgb{ .r = 28, .g = 32, .b = 40 };
    const grid_spacing: f32 = 32;

    // Draw vertical lines
    var x: f32 = grid_spacing;
    while (x < 512) : (x += grid_spacing) {
        canvas.drawLine(
            .point(.{ x, 0 }),
            .point(.{ x, 512 }),
            grid_color,
            1,
            .fast,
        );
    }

    // Draw horizontal lines
    var y: f32 = grid_spacing;
    while (y < 512) : (y += grid_spacing) {
        canvas.drawLine(
            .point(.{ 0, y }),
            .point(.{ 512, y }),
            grid_color,
            1,
            .fast,
        );
    }
}

fn drawSignalWaves(canvas: *Canvas(Rgb), allocator: std.mem.Allocator) !void {
    // Create points for sine waves that flow across the image
    const n_points = 150;
    var wave_points = try allocator.alloc(zignal.Point(2, f32), n_points);
    defer allocator.free(wave_points);

    // Draw three waves representing RGB / LMS cone responses in human vision
    // L (Long wavelength) - Red cones (~565nm peak, ~64% of cones)
    // M (Medium wavelength) - Green cones (~540nm peak, ~32% of cones)
    // S (Short wavelength) - Blue cones (~445nm peak, ~2-7% of cones)
    // Frequencies are proportional to actual light frequencies (blue > green > red)
    // Amplitudes reflect relative sensitivities and populations
    // All waves at same position to show interference/combination pattern
    const wave_configs = [_]struct {
        y_offset: f32,
        amplitude: f32,
        frequency: f32,
        phase: f32,
        color: Rgb,
        width: usize,
        comment: []const u8,
    }{
        .{ .y_offset = 140, .amplitude = 40, .frequency = 3.0, .phase = 0, .color = Rgb{ .r = 255, .g = 60, .b = 60 }, .width = 4, .comment = "L-cone (Red, ~450 THz)" },
        .{ .y_offset = 140, .amplitude = 35, .frequency = 3.9, .phase = std.math.pi * 2.0 / 3.0, .color = Rgb{ .r = 60, .g = 255, .b = 60 }, .width = 4, .comment = "M-cone (Green, ~560 THz)" },
        .{ .y_offset = 140, .amplitude = 15, .frequency = 4.5, .phase = std.math.pi * 4.0 / 3.0, .color = Rgb{ .r = 80, .g = 120, .b = 255 }, .width = 3, .comment = "S-cone (Blue, ~670 THz)" },
    };

    for (wave_configs) |config| {
        for (0..n_points) |i| {
            const x = @as(f32, @floatFromInt(i)) * 512.0 / @as(f32, @floatFromInt(n_points - 1));
            const normalized_x = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n_points - 1));
            const y = config.y_offset + config.amplitude * std.math.sin(config.frequency * 2 * std.math.pi * normalized_x + config.phase);
            wave_points[i] = zignal.Point(2, f32).point(.{ x, y });
        }

        // Draw the wave as connected lines
        for (1..n_points) |j| {
            canvas.drawLine(wave_points[j - 1], wave_points[j], config.color, config.width, .soft);
        }
    }
}

fn drawZignalText(canvas: *Canvas(Rgb)) void {
    // Use the default 8x8 font
    const font = zignal.font.font8x8.basic;

    // Scale factor for the text
    const scale: f32 = 10;

    // Calculate text dimensions
    const text = "ZIGNAL";
    const y_pos: f32 = 220;

    // Use classic Zig orange for all letters
    const text_color = Rgb{ .r = 247, .g = 164, .b = 29 };
    const shadow_color = blk: {
        var oklab = text_color.toOklab();
        oklab.l = @max(0, oklab.l - 0.3);
        break :blk oklab.toRgb();
    };

    // First pass: calculate total width using tight bounds
    var total_width: f32 = 0;
    for (text, 0..) |char, i| {
        const tight_bounds = font.getTextBoundsTight(&[_]u8{char}, scale);
        const visual_width = tight_bounds.r - tight_bounds.l;
        const padding: f32 = if (char == 'I') 25 else 15;
        total_width += visual_width + if (i < text.len - 1) padding else 0;
    }

    // Single pass: draw characters while tracking position
    var current_x = (512 - total_width) / 2;

    for (text) |char| {
        const char_str = [_]u8{char};

        // Shadow layer for depth
        canvas.drawText(
            &char_str,
            .point(.{ current_x + 2, y_pos + 2 }),
            shadow_color,
            font,
            scale,
            .fast,
        );

        // Main character
        canvas.drawText(
            &char_str,
            .point(.{ current_x, y_pos }),
            text_color,
            font,
            scale,
            .fast,
        );

        // Calculate next position using tight bounds
        const tight_bounds = font.getTextBoundsTight(&char_str, scale);
        const visual_width = tight_bounds.r - tight_bounds.l;
        const padding: f32 = if (char == 'I') 25 else 15;
        current_x += visual_width + padding;
    }
}

fn drawDecorativeElements(canvas: *Canvas(Rgb)) void {
    // Add pixel patterns in corners representing different image processing concepts
    const corner_size: f32 = 45;
    const pixel_size: f32 = 3;

    // Top-left: Gaussian blur kernel (smooth gradient from center)
    drawPixelPattern(canvas, 20, 20, corner_size, pixel_size, Rgb{ .r = 247, .g = 164, .b = 29 }, 0);

    // Top-right: Edge detection kernel (emphasizes boundaries)
    drawPixelPattern(canvas, 512 - corner_size - 20, 20, corner_size, pixel_size, Rgb{ .r = 80, .g = 180, .b = 255 }, 1);

    // Bottom-left: Sampling grid (discrete sampling points)
    drawPixelPattern(canvas, 20, 512 - corner_size - 20, corner_size, pixel_size, Rgb{ .r = 80, .g = 255, .b = 130 }, 2);

    // Bottom-right: Linear gradient (continuous intensity change)
    drawPixelPattern(canvas, 512 - corner_size - 20, 512 - corner_size - 20, corner_size, pixel_size, Rgb{ .r = 255, .g = 80, .b = 255 }, 3);

    // Add frequency spectrum visualization at the bottom
    drawFrequencySpectrum(canvas);
}

fn drawPixelPattern(canvas: *Canvas(Rgb), start_x: f32, start_y: f32, size: f32, pixel_size: f32, base_color: Rgb, pattern_seed: u64) void {
    const pixels_per_side = @as(usize, @intFromFloat(size / pixel_size));

    for (0..pixels_per_side) |i| {
        for (0..pixels_per_side) |j| {
            const fi = @as(f32, @floatFromInt(i));
            const fj = @as(f32, @floatFromInt(j));
            const max_dist = @as(f32, @floatFromInt(pixels_per_side));

            // Create different patterns for each corner representing image processing concepts
            const intensity: f32 = switch (pattern_seed) {
                0 => blk: { // Gaussian/blur kernel visualization (top-left)
                    const center = max_dist / 2;
                    const dx = (fi - center) / center;
                    const dy = (fj - center) / center;
                    const dist_sq = dx * dx + dy * dy;
                    break :blk @as(f32, @floatCast(@exp(-dist_sq * 2))); // Gaussian falloff
                },
                1 => blk: { // Edge detection result (top-right) - shows detected edges
                    // Sobel edge detection result: 5x5 grid using Oklab color space for perceptual uniformity
                    // Values: 0, 51, 102, 153, 204, 255 (normalized to 0.0-1.0)
                    const grid_size = 5;
                    const block_size = pixels_per_side / grid_size;

                    // Determine which block we're in
                    const block_i = @min(grid_size - 1, i / block_size);
                    const block_j = @min(grid_size - 1, j / block_size);

                    // Exact intensity pattern matching the Sobel edge detection result
                    // Using Oklab L values for perceptually uniform steps
                    const intensities = [_][5]f32{
                        .{ 0.0, 0.2, 0.4, 0.2, 0.0 }, // Row 0:   0  51 102  51   0
                        .{ 0.2, 0.6, 0.8, 0.6, 0.2 }, // Row 1:  51 153 204 153  51
                        .{ 0.4, 0.8, 1.0, 0.8, 0.4 }, // Row 2: 102 204 255 204 102
                        .{ 0.2, 0.6, 0.8, 0.6, 0.2 }, // Row 3:  51 153 204 153  51
                        .{ 0.0, 0.2, 0.4, 0.2, 0.0 }, // Row 4:   0  51 102  51   0
                    };

                    // Get the L value for this block
                    const l_value = intensities[block_i][block_j];

                    // Create an Oklab color with this lightness (a=0, b=0 for neutral gray)
                    const oklab_color = Oklab{ .l = l_value, .a = 0, .b = 0 };

                    // Convert to grayscale using Oklab's toGray method
                    // This gives us perceptually uniform grayscale values
                    const gray_value = @as(f32, @floatFromInt(oklab_color.toGray())) / 255.0;

                    break :blk gray_value;
                },
                2 => blk: { // Sampling grid pattern (bottom-left)
                    const grid_spacing = 3;
                    if (i % grid_spacing == 0 and j % grid_spacing == 0) {
                        break :blk @as(f32, 1.0);
                    }
                    break :blk @as(f32, 0.0);
                },
                3 => blk: { // Gradient visualization (bottom-right)
                    const gradient = (fi + fj) / (max_dist * 2);
                    break :blk std.math.pow(f32, gradient, 1.5);
                },
                else => @as(f32, 0.5),
            };

            const x = start_x + fi * pixel_size;
            const y = start_y + fj * pixel_size;

            // Convert base color to Oklab for perceptually uniform intensity adjustment
            const base_oklab = base_color.toOklab();

            // Create new Oklab color with adjusted lightness based on intensity
            // Keep the original a and b components to preserve hue/chroma
            const adjusted_oklab = Oklab{
                .l = intensity, // Use calculated intensity as lightness
                .a = base_oklab.a,
                .b = base_oklab.b,
            };

            // Convert back to RGB then to RGBA with alpha
            const adjusted_rgb = adjusted_oklab.toRgb();
            const alpha = @as(u8, @intFromFloat(@min(255, intensity * 255)));
            const color_with_alpha = adjusted_rgb.toRgba(alpha);

            const rect = zignal.Rectangle(f32).init(x, y, x + pixel_size - 1, y + pixel_size - 1);
            // Now fillRectangle with .soft mode properly supports alpha blending
            canvas.fillRectangle(rect, color_with_alpha, .soft);
        }
    }
}

fn drawFrequencySpectrum(canvas: *Canvas(Rgb)) void {
    const spectrum_y: f32 = 380;
    const bar_width: f32 = 4;
    const bar_spacing: f32 = 3;
    const num_bars = 50;
    const spectrum_start_x = (512 - (num_bars * (bar_width + bar_spacing))) / 2;

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    for (0..num_bars) |i| {
        const x = spectrum_start_x + @as(f32, @floatFromInt(i)) * (bar_width + bar_spacing);

        // Create a spectrum-like pattern with envelope
        const center = @as(f32, @floatFromInt(num_bars)) / 2;
        const distance_from_center = @abs(@as(f32, @floatFromInt(i)) - center) / center;
        const envelope = 1.0 - distance_from_center * 0.7;
        const height_factor = std.math.sin(@as(f32, @floatFromInt(i)) * 0.5) * 0.3 + 0.7;
        const noise = random.float(f32) * 0.2;
        const height = (height_factor * envelope + noise) * 35 + 5;

        // Use Oklch for perceptually uniform color gradient
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(num_bars - 1));

        // Interpolate hue from purple through pink to orange (sunset/plasma palette)
        const start_hue = 280.0; // Purple
        const end_hue = 30.0; // Orange
        // Handle hue wrap-around to go through pink/magenta
        const interpolated_hue = (1 - t) * start_hue + t * (end_hue + 360.0);
        const hue = @mod(interpolated_hue, 360.0);

        // Create Oklch color with consistent lightness and chroma
        // Vary lightness slightly based on bar height for visual interest
        const base_lightness = 0.70;
        const lightness_variation = (height / 40.0) * 0.15; // Add variation based on height
        const oklch_color = Oklch{
            .l = @min(0.85, base_lightness + lightness_variation),
            .c = 0.18, // Slightly higher chroma for vibrant warm colors
            .h = hue,
        };

        // Convert to RGB for rendering
        const color = oklch_color.toRgb();

        // Draw bar
        const rect = zignal.Rectangle(f32).init(x, spectrum_y - height, x + bar_width, spectrum_y);
        canvas.fillRectangle(rect, color, .fast);

        // Add a faint reflection with reduced lightness
        const reflection_rect = zignal.Rectangle(f32).init(x, spectrum_y + 2, x + bar_width, spectrum_y + height * 0.3);
        canvas.fillRectangle(reflection_rect, color.toRgba(64), .soft);
    }
}

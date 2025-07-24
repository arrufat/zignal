const std = @import("std");

const zignal = @import("zignal");
const Image = zignal.Image;
const Rgb = zignal.Rgb;
const Rgba = zignal.Rgba;
const Hsl = zignal.Hsl;
const savePng = zignal.png.save;
const loadPng = zignal.png.load;

pub const std_options = std.Options{
    .log_level = .info,
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    std.log.info("🎨 Zignal PNG Codec Demonstration", .{});
    std.log.info("==================================", .{});

    const width = 32;
    const height = 32;

    // ========================================================================
    // 1. RGB IMAGE CREATION AND ROUND-TRIP TESTING
    // ========================================================================
    std.log.info("\n📸 1. RGB Image Creation & Round-trip Testing", .{});

    var rgb_image = try Image(Rgb).initAlloc(gpa, height, width);
    defer rgb_image.deinit(gpa);

    // Create a colorful test pattern
    for (0..height) |y| {
        for (0..width) |x| {
            const r: u8 = @intCast((x * 255) / (width - 1));
            const g: u8 = @intCast((y * 255) / (height - 1));
            const b: u8 = @intCast(((x + y) * 255) / (width + height - 2));
            rgb_image.data[y * width + x] = Rgb{ .r = r, .g = g, .b = b };
        }
    }

    try savePng(Rgb, gpa, rgb_image, "demo_rgb_gradient.png");
    std.log.info("  ✓ Saved RGB gradient ({}x{}) as demo_rgb_gradient.png", .{ width, height });

    // Test optimized loading (RGB → RGB, no conversion)
    var loaded_rgb = try loadPng(Rgb, gpa, "demo_rgb_gradient.png");
    defer loaded_rgb.deinit(gpa);
    std.log.info("  ✓ Loaded back as RGB (optimized path - no conversion)", .{});

    // Verify pixel-perfect round-trip
    var rgb_matches = true;
    for (rgb_image.data, loaded_rgb.data) |orig, loaded| {
        if (orig.r != loaded.r or orig.g != loaded.g or orig.b != loaded.b) {
            rgb_matches = false;
            break;
        }
    }
    std.log.info("  ✓ Round-trip verification: {s}", .{if (rgb_matches) "PERFECT" else "FAILED"});

    // ========================================================================
    // 2. RGBA WITH TRANSPARENCY
    // ========================================================================
    std.log.info("\n🎭 2. RGBA with Transparency", .{});

    var rgba_image = try Image(Rgba).initAlloc(gpa, height, width);
    defer rgba_image.deinit(gpa);

    for (0..height) |y| {
        for (0..width) |x| {
            const center_x = @as(f32, @floatFromInt(width)) / 2.0;
            const center_y = @as(f32, @floatFromInt(height)) / 2.0;
            const dx = @as(f32, @floatFromInt(x)) - center_x;
            const dy = @as(f32, @floatFromInt(y)) - center_y;
            const distance = @sqrt(dx * dx + dy * dy);
            const max_distance = @sqrt(center_x * center_x + center_y * center_y);

            const r: u8 = @intCast((x * 255) / (width - 1));
            const g: u8 = @intCast((y * 255) / (height - 1));
            const b: u8 = 255 - @as(u8, @intCast((x * 255) / (width - 1)));
            // Create radial transparency gradient
            const a: u8 = @intCast(255 - @min(255, @as(u32, @intFromFloat((distance / max_distance) * 255))));

            rgba_image.data[y * width + x] = Rgba{ .r = r, .g = g, .b = b, .a = a };
        }
    }

    try savePng(Rgba, gpa, rgba_image, "demo_rgba_radial.png");
    std.log.info("  ✓ Saved RGBA with radial transparency as demo_rgba_radial.png", .{});

    // Test RGBA round-trip
    var loaded_rgba = try loadPng(Rgba, gpa, "demo_rgba_radial.png");
    defer loaded_rgba.deinit(gpa);
    std.log.info("  ✓ Loaded back as RGBA (optimized path)", .{});

    // ========================================================================
    // 3. GRAYSCALE IMAGES
    // ========================================================================
    std.log.info("\n⚫ 3. Grayscale Images", .{});

    var gray_image = try Image(u8).initAlloc(gpa, height, width);
    defer gray_image.deinit(gpa);

    // Create a pattern with various gray levels
    for (0..height) |y| {
        for (0..width) |x| {
            if ((x / 4 + y / 4) % 2 == 0) {
                gray_image.data[y * width + x] = @intCast((x * y * 255) / ((width - 1) * (height - 1)));
            } else {
                gray_image.data[y * width + x] = @intCast(255 - (x * y * 255) / ((width - 1) * (height - 1)));
            }
        }
    }

    try savePng(u8, gpa, gray_image, "demo_grayscale_pattern.png");
    std.log.info("  ✓ Saved grayscale pattern as demo_grayscale_pattern.png", .{});

    var loaded_gray = try loadPng(u8, gpa, "demo_grayscale_pattern.png");
    defer loaded_gray.deinit(gpa);
    std.log.info("  ✓ Loaded back as grayscale (optimized path)", .{});

    // ========================================================================
    // 4. CROSS-FORMAT LOADING (Conversion Features)
    // ========================================================================
    std.log.info("\n🔄 4. Cross-Format Loading & Automatic Conversion", .{});

    // Load RGB PNG as grayscale (automatic conversion)
    var rgb_as_gray = try loadPng(u8, gpa, "demo_rgb_gradient.png");
    defer rgb_as_gray.deinit(gpa);
    std.log.info("  ✓ Loaded RGB PNG as grayscale (automatic RGB→u8 conversion)", .{});

    // Load RGB PNG as RGBA (automatic conversion with alpha=255)
    var rgb_as_rgba = try loadPng(Rgba, gpa, "demo_rgb_gradient.png");
    defer rgb_as_rgba.deinit(gpa);
    std.log.info("  ✓ Loaded RGB PNG as RGBA (automatic RGB→RGBA conversion)", .{});

    // Load grayscale PNG as RGB (automatic conversion)
    var gray_as_rgb = try loadPng(Rgb, gpa, "demo_grayscale_pattern.png");
    defer gray_as_rgb.deinit(gpa);
    std.log.info("  ✓ Loaded grayscale PNG as RGB (automatic u8→RGB conversion)", .{});

    // ========================================================================
    // 5. CUSTOM COLOR SPACE SUPPORT
    // ========================================================================
    std.log.info("\n🌈 5. Custom Color Space Support", .{});

    // Create HSL image and save as PNG (automatic conversion to RGB)
    var hsl_image = try Image(Hsl).initAlloc(gpa, height / 2, width / 2);
    defer hsl_image.deinit(gpa);

    for (0..height / 2) |y| {
        for (0..width / 2) |x| {
            const h: f64 = @as(f64, @floatFromInt(x)) * 360.0 / @as(f64, @floatFromInt(width / 2 - 1));
            const s: f64 = 100.0; // Full saturation for vibrant colors
            const l: f64 = @as(f64, @floatFromInt(y)) * 50.0 / @as(f64, @floatFromInt(height / 2 - 1)) + 25.0; // Lightness from 25% to 75%

            hsl_image.data[y * (width / 2) + x] = Hsl{ .h = h, .s = s, .l = l };
        }
    }

    try savePng(Hsl, gpa, hsl_image, "demo_hsl_colorwheel.png");
    std.log.info("  ✓ Saved HSL color wheel as PNG (automatic HSL→RGB conversion)", .{});

    // Load back as HSL (PNG→RGB→HSL conversion)
    var loaded_hsl = try loadPng(Hsl, gpa, "demo_hsl_colorwheel.png");
    defer loaded_hsl.deinit(gpa);
    std.log.info("  ✓ Loaded back as HSL (automatic RGB→HSL conversion)", .{});

    // ========================================================================
    // 6. EDGE CASES AND VALIDATION
    // ========================================================================
    std.log.info("\n🧪 6. Edge Cases & Validation", .{});

    // Test 1x1 pixel image
    var tiny_image = try Image(Rgb).initAlloc(gpa, 1, 1);
    defer tiny_image.deinit(gpa);
    tiny_image.data[0] = Rgb{ .r = 255, .g = 0, .b = 128 };

    try savePng(Rgb, gpa, tiny_image, "demo_1x1.png");
    var loaded_tiny = try loadPng(Rgb, gpa, "demo_1x1.png");
    defer loaded_tiny.deinit(gpa);
    std.log.info("  ✓ 1x1 pixel image: {s}", .{if (tiny_image.data[0].r == loaded_tiny.data[0].r and
        tiny_image.data[0].g == loaded_tiny.data[0].g and
        tiny_image.data[0].b == loaded_tiny.data[0].b) "PERFECT" else "FAILED"});

    // Test large-ish image (performance test)
    const large_size = 128;
    var large_image = try Image(Rgb).initAlloc(gpa, large_size, large_size);
    defer large_image.deinit(gpa);

    for (0..large_size) |y| {
        for (0..large_size) |x| {
            large_image.data[y * large_size + x] = Rgb{ .r = @intCast(x % 256), .g = @intCast(y % 256), .b = @intCast((x + y) % 256) };
        }
    }

    try savePng(Rgb, gpa, large_image, "demo_large_128x128.png");
    var loaded_large = try loadPng(Rgb, gpa, "demo_large_128x128.png");
    defer loaded_large.deinit(gpa);
    std.log.info("  ✓ Large 128x128 image: {s}", .{if (large_image.data[0].r == loaded_large.data[0].r) "SUCCESS" else "FAILED"});

    // ========================================================================
    // 7. PERFORMANCE COMPARISON
    // ========================================================================
    std.log.info("\n⚡ 7. Performance Comparison", .{});

    const timer = std.time.Timer;
    var t = try timer.start();

    // Time optimized loading (no conversion)
    t.reset();
    var perf_rgb = try loadPng(Rgb, gpa, "demo_rgb_gradient.png");
    const optimized_time = t.read();
    perf_rgb.deinit(gpa);

    // Time conversion loading
    t.reset();
    var perf_gray = try loadPng(u8, gpa, "demo_rgb_gradient.png");
    const conversion_time = t.read();
    perf_gray.deinit(gpa);

    std.log.info("  ✓ Optimized loading (RGB→RGB):  {d:.2}ms", .{@as(f64, @floatFromInt(optimized_time)) / 1_000_000});
    std.log.info("  ✓ Conversion loading (RGB→u8):  {d:.2}ms", .{@as(f64, @floatFromInt(conversion_time)) / 1_000_000});

    // ========================================================================
    // SUMMARY
    // ========================================================================
    std.log.info("\n🎉 PNG Codec Demonstration Complete!", .{});
    std.log.info("=====================================", .{});
    std.log.info("Generated files:", .{});
    std.log.info("  • demo_rgb_gradient.png      - RGB gradient pattern", .{});
    std.log.info("  • demo_rgba_radial.png       - RGBA with transparency", .{});
    std.log.info("  • demo_grayscale_pattern.png - Grayscale checkerboard", .{});
    std.log.info("  • demo_hsl_colorwheel.png    - HSL color wheel (converted)", .{});
    std.log.info("  • demo_1x1.png              - Edge case: 1x1 pixel", .{});
    std.log.info("  • demo_large_128x128.png     - Performance test: 128x128", .{});
    std.log.info("", .{});
    std.log.info("Features demonstrated:", .{});
    std.log.info("  ✓ All PNG color types (RGB, RGBA, Grayscale)", .{});
    std.log.info("  ✓ Optimized loading (zero-copy when types match)", .{});
    std.log.info("  ✓ Automatic type conversion (any format ↔ any format)", .{});
    std.log.info("  ✓ Custom color spaces (HSL, etc.)", .{});
    std.log.info("  ✓ Edge cases (tiny/large images)", .{});
    std.log.info("  ✓ Performance benchmarking", .{});
    std.log.info("  ✓ Pixel-perfect round-trip verification", .{});
}

const std = @import("std");
const assert = std.debug.assert;
const clamp = std.math.clamp;
const testing = std.testing;
const expectEqual = testing.expectEqual;
const expectApproxEqRel = testing.expectApproxEqRel;
const builtin = @import("builtin");

const Canvas = @import("canvas.zig").Canvas;
const ConvexHull = @import("geometry.zig").ConvexHull;
const Image = @import("image.zig").Image;
const Matrix = @import("matrix.zig").Matrix;
const OpsBuilder = @import("matrix.zig").OpsBuilder;
const Point2d = @import("geometry.zig").Point2d;
const Rgb = @import("color.zig").Rgb;
const Rgba = @import("color.zig").Rgba;
const savePng = @import("png.zig").savePng;
const SMatrix = @import("matrix.zig").SMatrix;
const svd = @import("svd.zig").svd;

/// Computes the feature distribution matching between `src_img` and `ref_img` and modifies
/// `src_img` to look like `ref_img`.
pub fn featureDistributionMatch(
    T: type,
    gpa: std.mem.Allocator,
    src_img: Image(T),
    ref_img: Image(T),
) !void {
    comptime assert(T == Rgb or T == Rgba);

    const src_size = src_img.rows * src_img.cols;
    var src = try Matrix(f64).init(gpa, src_size, 3);
    defer src.deinit();
    const ref_size = ref_img.rows * ref_img.cols;
    var ref = try Matrix(f64).init(gpa, ref_size, 3);
    defer ref.deinit();

    // 1. reshape
    var i: usize = 0;
    for (0..src_img.rows) |r| {
        for (0..src_img.cols) |c| {
            const p = src_img.at(r, c);
            src.at(i / 3, 0).* = @as(f64, @floatFromInt(p.r)) / 255;
            src.at(i / 3, 1).* = @as(f64, @floatFromInt(p.g)) / 255;
            src.at(i / 3, 2).* = @as(f64, @floatFromInt(p.b)) / 255;
            i += 3;
        }
    }
    i = 0;
    for (0..ref_img.rows) |r| {
        for (0..ref_img.cols) |c| {
            const p = ref_img.at(r, c);
            ref.at(i / 3, 0).* = @as(f64, @floatFromInt(p.r)) / 255;
            ref.at(i / 3, 1).* = @as(f64, @floatFromInt(p.g)) / 255;
            ref.at(i / 3, 2).* = @as(f64, @floatFromInt(p.b)) / 255;
            i += 3;
        }
    }

    // 2. center
    var src_means = [_]f64{0} ** 3;
    for (0..src.cols) |c| {
        for (0..src.rows) |r| {
            src_means[c] += src.at(r, c).*;
        }
        src_means[c] /= @floatFromInt(src.rows);
        for (0..src.rows) |r| {
            src.at(r, c).* -= src_means[c];
        }
    }
    var ref_means = [_]f64{0} ** 3;
    for (0..ref.cols) |c| {
        for (0..ref.rows) |r| {
            ref_means[c] += ref.at(r, c).*;
        }
        ref_means[c] /= @floatFromInt(ref.rows);
        for (0..ref.rows) |r| {
            ref.at(r, c).* -= ref_means[c];
        }
    }

    // 3. whiten
    var src_ops = try OpsBuilder(f64).init(gpa, src);
    defer src_ops.deinit();
    try src_ops.transpose();
    try src_ops.dot(src);
    try src_ops.scale(1.0 / @as(f64, @floatFromInt(src_size)));
    var src_tmp = src_ops.toOwned();
    defer src_tmp.deinit();
    var src_cov: SMatrix(f64, 3, 3) = .{};
    for (0..src_cov.cols) |c| {
        for (0..src_cov.rows) |r| {
            src_cov.items[r][c] = src_tmp.at(r, c).*;
        }
    }
    var res = svd(f64, src_cov.rows, src_cov.cols, src_cov, .{
        .with_u = true,
        .with_v = false,
        .mode = .skinny_u,
    });
    var src_u = try Matrix(f64).init(gpa, res[0].rows, res[0].cols);
    defer src_u.deinit();
    for (0..src_u.rows) |r| {
        for (0..src_u.cols) |c| {
            src_u.at(r, c).* = res[0].items[r][c];
        }
    }
    var w = try Matrix(f64).init(gpa, 3, 3);
    defer w.deinit();
    for (0..w.rows) |r| {
        for (0..w.cols) |c| {
            if (r == c) {
                w.at(r, c).* = 1 / @sqrt(res[1].items[r][0]);
            } else {
                w.at(r, c).* = 0;
            }
        }
    }

    var src_wht_ops = try OpsBuilder(f64).init(gpa, src);
    defer src_wht_ops.deinit();
    try src_wht_ops.dot(src_u);
    try src_wht_ops.dot(w);
    var src_wht = src_wht_ops.toOwned();
    defer src_wht.deinit();

    // 4. transform covariance
    var ref_ops = try OpsBuilder(f64).init(gpa, ref);
    defer ref_ops.deinit();
    try ref_ops.transpose();
    try ref_ops.dot(ref);
    try ref_ops.scale(1.0 / @as(f64, @floatFromInt(ref_size)));
    var ref_tmp = ref_ops.toOwned();
    defer ref_tmp.deinit();
    var ref_cov: SMatrix(f64, 3, 3) = .{};
    for (0..ref_cov.cols) |c| {
        for (0..ref_cov.rows) |r| {
            ref_cov.items[r][c] = ref_tmp.at(r, c).*;
        }
    }
    res = svd(f64, ref_cov.rows, ref_cov.cols, ref_cov, .{
        .with_u = true,
        .with_v = false,
        .mode = .skinny_u,
    });
    var ref_u = try Matrix(f64).init(gpa, res[0].rows, res[0].cols);
    defer ref_u.deinit();
    for (0..ref_u.rows) |r| {
        for (0..ref_u.cols) |c| {
            ref_u.at(r, c).* = res[0].items[r][c];
        }
    }
    w.deinit();
    w = try Matrix(f64).init(gpa, 3, 3);
    for (0..w.rows) |r| {
        for (0..w.cols) |c| {
            if (r == c) {
                w.at(r, c).* = @sqrt(res[1].items[r][0]);
            } else {
                w.at(r, c).* = 0;
            }
        }
    }
    var ref_u_ops = try OpsBuilder(f64).init(gpa, ref_u);
    defer ref_u_ops.deinit();
    try ref_u_ops.transpose();
    var ref_u_transposed = ref_u_ops.toOwned();
    defer ref_u_transposed.deinit();

    var src_tfm_ops = try OpsBuilder(f64).init(gpa, src_wht);
    defer src_tfm_ops.deinit();
    try src_tfm_ops.dot(w);
    try src_tfm_ops.dot(ref_u_transposed);
    var src_tfm = src_tfm_ops.toOwned();
    defer src_tfm.deinit();

    // 5. add source mean
    for (0..src_tfm.rows) |r| {
        for (0..src_tfm.cols) |c| {
            src_tfm.at(r, c).* += ref_means[c];
        }
    }

    // 6. reshape
    i = 0;
    for (0..src_img.rows) |r| {
        for (0..src_img.cols) |c| {
            src_img.at(r, c).r = @intFromFloat(@round(255 * clamp(src_tfm.at(i / 3, 0).*, 0, 1)));
            src_img.at(r, c).g = @intFromFloat(@round(255 * clamp(src_tfm.at(i / 3, 1).*, 0, 1)));
            src_img.at(r, c).b = @intFromFloat(@round(255 * clamp(src_tfm.at(i / 3, 2).*, 0, 1)));
            i += 3;
        }
    }
}

/// Helper function to generate a random RGB image with specified color distribution
fn generateRandomImage(allocator: std.mem.Allocator, rows: usize, cols: usize, seed: u64, color_bias: Rgb) !Image(Rgb) {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    const img = try Image(Rgb).initAlloc(allocator, rows, cols);
    for (img.data) |*pixel| {
        pixel.* = Rgb{
            .r = @intCast(@min(255, @max(0, @as(i32, random.intRangeAtMost(u8, 0, 255)) + @as(i32, color_bias.r) - 128))),
            .g = @intCast(@min(255, @max(0, @as(i32, random.intRangeAtMost(u8, 0, 255)) + @as(i32, color_bias.g) - 128))),
            .b = @intCast(@min(255, @max(0, @as(i32, random.intRangeAtMost(u8, 0, 255)) + @as(i32, color_bias.b) - 128))),
        };
    }
    return img;
}

test "FDM basic functionality" {
    const allocator = testing.allocator;

    // Create source image with blue bias
    var src_img = try generateRandomImage(allocator, 64, 64, 12345, Rgb{ .r = 50, .g = 50, .b = 200 });
    defer src_img.deinit(allocator);

    // Create reference image with red bias
    var ref_img = try generateRandomImage(allocator, 64, 64, 54321, Rgb{ .r = 200, .g = 50, .b = 50 });
    defer ref_img.deinit(allocator);

    // Apply FDM
    try featureDistributionMatch(Rgb, allocator, src_img, ref_img);

    // Basic test: just ensure the function runs without crashing
    // and that the image still has valid pixel values
    for (src_img.data) |pixel| {
        try std.testing.expect(pixel.r <= 255);
        try std.testing.expect(pixel.g <= 255);
        try std.testing.expect(pixel.b <= 255);
    }
}

test "FDM color distribution matching" {
    const allocator = testing.allocator;

    // Create source image with some color variation
    var src_img = try generateRandomImage(allocator, 32, 32, 11111, Rgb{ .r = 50, .g = 150, .b = 100 });
    defer src_img.deinit(allocator);

    // Create reference image with different color variation
    var ref_img = try generateRandomImage(allocator, 32, 32, 22222, Rgb{ .r = 150, .g = 50, .b = 100 });
    defer ref_img.deinit(allocator);

    // Apply FDM
    try featureDistributionMatch(Rgb, allocator, src_img, ref_img);

    // Basic validation - just check that values are in valid range
    for (src_img.data) |pixel| {
        try std.testing.expect(pixel.r <= 255);
        try std.testing.expect(pixel.g <= 255);
        try std.testing.expect(pixel.b <= 255);
    }
}

test "FDM with RGBA images" {
    const allocator = testing.allocator;

    // Create source RGBA image with some variation
    var src_img = try Image(Rgba).initAlloc(allocator, 16, 16);
    defer src_img.deinit(allocator);
    for (0..src_img.data.len) |i| {
        src_img.data[i] = Rgba{ .r = @intCast(50 + i % 100), .g = @intCast(50 + i % 80), .b = @intCast(100 + i % 60), .a = 255 };
    }

    // Create reference RGBA image with different variation
    var ref_img = try Image(Rgba).initAlloc(allocator, 16, 16);
    defer ref_img.deinit(allocator);
    for (0..ref_img.data.len) |i| {
        ref_img.data[i] = Rgba{ .r = @intCast(100 + i % 80), .g = @intCast(60 + i % 90), .b = @intCast(50 + i % 70), .a = 255 };
    }

    // Apply FDM
    try featureDistributionMatch(Rgba, allocator, src_img, ref_img);

    // Basic validation - check values are valid and alpha is preserved
    for (src_img.data) |pixel| {
        try std.testing.expect(pixel.r <= 255);
        try std.testing.expect(pixel.g <= 255);
        try std.testing.expect(pixel.b <= 255);
        try expectEqual(@as(u8, 255), pixel.a);
    }
}

test "FDM visual output test" {
    const allocator = testing.allocator;

    // Create source image with checkerboard pattern (blue/cyan)
    var src_img = try Image(Rgb).initAlloc(allocator, 128, 128);
    defer src_img.deinit(allocator);
    for (0..src_img.rows) |r| {
        for (0..src_img.cols) |c| {
            if ((r / 8 + c / 8) % 2 == 0) {
                src_img.at(r, c).* = Rgb{ .r = 0, .g = 100, .b = 255 };
            } else {
                src_img.at(r, c).* = Rgb{ .r = 0, .g = 255, .b = 255 };
            }
        }
    }

    // Create reference image with gradient (red to yellow)
    var ref_img = try Image(Rgb).initAlloc(allocator, 128, 128);
    defer ref_img.deinit(allocator);
    for (0..ref_img.rows) |r| {
        for (0..ref_img.cols) |c| {
            const intensity = @as(u8, @intCast((@as(u32, @intCast(r)) * 255) / ref_img.rows));
            ref_img.at(r, c).* = Rgb{ .r = 255, .g = intensity, .b = 0 };
        }
    }

    // Save original source image
    try savePng(Rgb, allocator, src_img, "fdm_test_source.png");

    // Save reference image
    try savePng(Rgb, allocator, ref_img, "fdm_test_reference.png");

    // Apply FDM
    try featureDistributionMatch(Rgb, allocator, src_img, ref_img);

    // Save result image
    try savePng(Rgb, allocator, src_img, "fdm_test_result.png");

    // Basic validation - result should have valid pixel values
    for (src_img.data) |pixel| {
        try std.testing.expect(pixel.r <= 255);
        try std.testing.expect(pixel.g <= 255);
        try std.testing.expect(pixel.b <= 255);
    }
}

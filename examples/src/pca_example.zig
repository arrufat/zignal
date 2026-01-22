const std = @import("std");

const zignal = @import("zignal");
const Image = zignal.Image;
const Canvas = zignal.Canvas;
const Pca = zignal.Pca;
const Point = zignal.Point;
const Matrix = zignal.Matrix;

const Rgb = zignal.Rgb(u8);
const Bounds = struct { min: @Vector(2, f64), max: @Vector(2, f64) };

/// Generate a 2D point cloud with a clear dominant direction
fn generatePointCloud(allocator: std.mem.Allocator, num_points: usize) !Matrix(f64) {
    var points: Matrix(f64) = try .init(allocator, num_points, 2);

    // Use a deterministic random number generator for reproducible results
    var prng: std.Random.DefaultPrng = .init(42);
    var rand = prng.random();

    // Generate points along a dominant diagonal direction with some noise
    // Main direction: (1, 0.6) - creates an elongated cloud
    const main_direction = @Vector(2, f64){ 1.0, 0.6 };
    const noise_strength = 0.3;

    for (0..num_points) |i| {
        // Parameter along main direction
        const t = (rand.float(f64) - 0.5) * 4.0; // Range: -2 to 2

        // Point along main direction
        const main_point = main_direction * @as(@Vector(2, f64), @splat(t));

        // Add perpendicular noise
        const noise_x = (rand.float(f64) - 0.5) * noise_strength;
        const noise_y = (rand.float(f64) - 0.5) * noise_strength;
        const noise = @Vector(2, f64){ noise_x, noise_y };

        const point = main_point + noise;

        points.at(i, 0).* = point[0];
        points.at(i, 1).* = point[1];

        // Add some outliers for more realistic data
        if (i < num_points / 20) {
            points.at(i, 0).* += (rand.float(f64) - 0.5) * 2.0;
            points.at(i, 1).* += (rand.float(f64) - 0.5) * 2.0;
        }
    }

    return points;
}

/// Convert world coordinates to canvas coordinates with uniform scaling to preserve angles
/// Note: Y axis is flipped since image coordinates have Y=0 at top
fn worldToCanvas(world_point: @Vector(2, f64), canvas_size: f32, world_bounds: Bounds) Point(2, f32) {
    const world_size = world_bounds.max - world_bounds.min;
    const margin = canvas_size * 0.1; // 10% margin
    const draw_size = canvas_size - 2 * margin;

    // Use uniform scaling based on the larger dimension to preserve angles
    const max_world_size = @max(world_size[0], world_size[1]);
    const scale = draw_size / @as(f32, @floatCast(max_world_size));

    // Center the coordinate system
    const world_center = (world_bounds.min + world_bounds.max) / @as(@Vector(2, f64), @splat(2.0));
    const canvas_center = canvas_size / 2.0;

    // Transform with uniform scaling
    const centered_point = world_point - world_center;
    const canvas_x = @as(f32, @floatCast(centered_point[0])) * scale + canvas_center;
    const canvas_y = -@as(f32, @floatCast(centered_point[1])) * scale + canvas_center; // Flip Y axis

    return .init(.{ canvas_x, canvas_y });
}

/// Find bounding box of point cloud
fn findBounds(points: Matrix(f64)) Bounds {
    if (points.rows == 0) return .{ .min = @splat(0), .max = @splat(1) };

    var min_point = @Vector(2, f64){ points.at(0, 0).*, points.at(0, 1).* };
    var max_point = @Vector(2, f64){ points.at(0, 0).*, points.at(0, 1).* };

    for (1..points.rows) |i| {
        const point = @Vector(2, f64){ points.at(i, 0).*, points.at(i, 1).* };
        min_point = @min(min_point, point);
        max_point = @max(max_point, point);
    }

    // Add some padding
    const padding = (max_point - min_point) * @as(@Vector(2, f64), @splat(0.1));
    min_point -= padding;
    max_point += padding;

    return .{ .min = min_point, .max = max_point };
}

/// Draw points on canvas
fn drawPoints(canvas: Canvas(Rgb), points: Matrix(f64), bounds: Bounds, color: Rgb, radius: f32) void {
    const canvas_size = @as(f32, @floatFromInt(canvas.image.cols));

    for (0..points.rows) |i| {
        const pt = @Vector(2, f64){ points.at(i, 0).*, points.at(i, 1).* };
        const canvas_point = worldToCanvas(pt, canvas_size, bounds);
        canvas.drawCircle(canvas_point, radius, color, 1, .soft);
    }
}

/// Draw PCA axes on canvas
fn drawPcaAxes(canvas: Canvas(Rgb), pca: Pca(f64), bounds: Bounds) !void {
    const canvas_size = @as(f32, @floatFromInt(canvas.image.cols));
    const mean_slice = pca.getMean();
    const mean_vec = @Vector(2, f64){ mean_slice[0], mean_slice[1] };
    const mean_canvas = worldToCanvas(mean_vec, canvas_size, bounds);

    // Draw mean point
    canvas.drawCircle(mean_canvas, 8, Rgb{ .r = 255, .g = 255, .b = 0 }, 2, .soft);

    // Get principal components (eigenvectors)
    const scale = 1.5; // Scale factor for drawing axes

    for (0..pca.num_components) |i| {
        var component: @Vector(2, f64) = undefined;
        inline for (0..2) |j| {
            component[j] = pca.components.at(j, i).*;
        }

        // Scale component for visualization
        const axis_end = mean_vec + component * @as(@Vector(2, f64), @splat(scale));
        const axis_start = mean_vec - component * @as(@Vector(2, f64), @splat(scale));

        const start_canvas = worldToCanvas(axis_start, canvas_size, bounds);
        const end_canvas = worldToCanvas(axis_end, canvas_size, bounds);

        // Use different colors for different components
        const axis_color = if (i == 0)
            Rgb{ .r = 255, .g = 0, .b = 0 } // Red for first PC
        else
            Rgb{ .r = 0, .g = 255, .b = 0 }; // Green for second PC

        canvas.drawLine(start_canvas, end_canvas, axis_color, 3, .soft);

        // Draw arrowhead at end
        const arrow_size = 10.0;
        const dir_x = end_canvas.x() - start_canvas.x();
        const dir_y = end_canvas.y() - start_canvas.y();
        const length = @sqrt(dir_x * dir_x + dir_y * dir_y);

        if (length > 0) {
            const norm_dir_x = dir_x / length;
            const norm_dir_y = dir_y / length;

            const arrow1: Point(2, f32) = .init(.{
                end_canvas.x() - arrow_size * (norm_dir_x + norm_dir_y * 0.5),
                end_canvas.y() - arrow_size * (norm_dir_y - norm_dir_x * 0.5),
            });
            const arrow2: Point(2, f32) = .init(.{
                end_canvas.x() - arrow_size * (norm_dir_x - norm_dir_y * 0.5),
                end_canvas.y() - arrow_size * (norm_dir_y + norm_dir_x * 0.5),
            });

            canvas.drawLine(end_canvas, arrow1, axis_color, 2, .soft);
            canvas.drawLine(end_canvas, arrow2, axis_color, 2, .soft);
        }
    }
}

/// Project points using PCA and create new aligned dataset
fn projectAndAlign(pca: Pca(f64), original_points: Matrix(f64)) !Matrix(f64) {
    // Use the batch transform method to project all points at once
    return try pca.transform(original_points);
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();
    const io = std.Io.Threaded.global_single_threaded.ioBasic();

    const canvas_size = 400;
    const num_points = 200;

    // 1. Generate point cloud with dominant direction
    var original_points = try generatePointCloud(gpa, num_points);
    defer original_points.deinit();

    // 2. Create original visualization
    var original_image: Image(Rgb) = try .init(gpa, canvas_size, canvas_size);
    defer original_image.deinit(gpa);

    const original_canvas: Canvas(Rgb) = .init(gpa, original_image);
    original_canvas.fill(Rgb{ .r = 20, .g = 20, .b = 40 }); // Dark blue background

    const original_bounds = findBounds(original_points);

    // Draw original points
    drawPoints(original_canvas, original_points, original_bounds, Rgb{ .r = 100, .g = 150, .b = 255 }, 3.0); // Light blue points

    // 3. Compute PCA
    var pca: Pca(f64) = try .init(gpa);
    defer pca.deinit();

    try pca.fit(original_points, null); // Keep all components

    // Draw PCA axes on original image
    try drawPcaAxes(original_canvas, pca, original_bounds);

    // 4. Project points to PCA space and create aligned visualization
    var aligned_points = try projectAndAlign(pca, original_points);
    defer aligned_points.deinit();

    var aligned_image: Image(Rgb) = try .init(gpa, canvas_size, canvas_size);
    defer aligned_image.deinit(gpa);

    const aligned_canvas: Canvas(Rgb) = .init(gpa, aligned_image);
    aligned_canvas.fill(Rgb{ .r = 40, .g = 20, .b = 20 }); // Dark red background

    const aligned_bounds = findBounds(aligned_points);

    // Draw aligned points (note: aligned_points is now in PCA space)
    drawPoints(aligned_canvas, aligned_points, aligned_bounds, Rgb{ .r = 255, .g = 150, .b = 100 }, 3.0); // Light orange points

    // Draw coordinate axes in aligned space
    const zero_point = @Vector(2, f64){ 0.0, 0.0 };
    _ = zero_point; // Mark as used to avoid unused variable warning

    // X-axis (red) - corresponds to first principal component
    const x_axis_end = worldToCanvas(@Vector(2, f64){ aligned_bounds.max[0] * 0.8, 0.0 }, @floatFromInt(canvas_size), aligned_bounds);
    const x_axis_start = worldToCanvas(@Vector(2, f64){ aligned_bounds.min[0] * 0.8, 0.0 }, @floatFromInt(canvas_size), aligned_bounds);
    aligned_canvas.drawLine(x_axis_start, x_axis_end, Rgb{ .r = 255, .g = 0, .b = 0 }, 2, .soft);

    // Y-axis (green) - corresponds to second principal component
    const y_axis_end = worldToCanvas(@Vector(2, f64){ 0.0, aligned_bounds.max[1] * 0.8 }, @floatFromInt(canvas_size), aligned_bounds);
    const y_axis_start = worldToCanvas(@Vector(2, f64){ 0.0, aligned_bounds.min[1] * 0.8 }, @floatFromInt(canvas_size), aligned_bounds);
    aligned_canvas.drawLine(y_axis_start, y_axis_end, Rgb{ .r = 0, .g = 255, .b = 0 }, 2, .soft);

    // Log results
    std.log.info("PCA Analysis completed successfully", .{});

    // Save images if not running in WASM
    try original_image.save(io, gpa, "pca_original.png");
    try aligned_canvas.image.save(io, gpa, "pca_aligned.png");
}

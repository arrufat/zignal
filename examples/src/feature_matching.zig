const std = @import("std");
const builtin = @import("builtin");

const zignal = @import("zignal");
const BruteForceMatcher = zignal.BruteForceMatcher;
const Image = zignal.Image;
const Orb = zignal.Orb;
const Rgba = zignal.Rgba;

const js = @import("js.zig");
pub const alloc = js.alloc;
pub const free = js.free;

pub const std_options: std.Options = .{
    .logFn = if (builtin.cpu.arch.isWasm()) js.logFn else std.log.defaultLog,
    .log_level = std.log.default_level,
};

pub fn panic(msg: []const u8, st: ?*std.builtin.StackTrace, addr: ?usize) noreturn {
    _ = st;
    _ = addr;
    std.log.err("panic: {s}", .{msg});
    @trap();
}

// Export memory management functions from js.zig
/// Detect ORB features in an image
/// Returns: [num_features, kp1_x, kp1_y, kp1_size, kp1_angle, kp2_x, ...]
pub export fn detectFeatures(
    image_ptr: [*]Rgba,
    rows: usize,
    cols: usize,
    result_ptr: [*]f32,
    max_features: usize,
) usize {
    const allocator = std.heap.wasm_allocator;

    const img_size = rows * cols;
    const img: Image(Rgba) = .initFromSlice(rows, cols, image_ptr[0..img_size]);

    // Convert to grayscale
    var gray = img.convert(u8, allocator) catch |err| {
        std.log.err("Failed to convert to grayscale: {}", .{err});
        return 0;
    };
    defer gray.deinit(allocator);

    // Create ORB detector
    var orb: Orb = .{
        .n_features = @intCast(@min(max_features, 500)),
        .scale_factor = 1.2,
        .n_levels = 8,
        .fast_threshold = 20,
    };

    // Detect features
    const features = orb.detectAndCompute(gray, allocator) catch |err| {
        std.log.err("Failed to detect features: {}", .{err});
        return 0;
    };
    defer allocator.free(features.keypoints);
    defer allocator.free(features.descriptors);

    // Copy keypoints to result buffer
    const num_features = features.keypoints.len;
    result_ptr[0] = @floatFromInt(num_features);

    var idx: usize = 1;
    for (features.keypoints) |kp| {
        result_ptr[idx] = kp.x;
        result_ptr[idx + 1] = kp.y;
        result_ptr[idx + 2] = kp.size;
        result_ptr[idx + 3] = kp.angle;
        result_ptr[idx + 4] = @floatFromInt(kp.octave);
        idx += 5;
    }

    // Store descriptors after keypoints
    // Each descriptor is 32 bytes (256 bits)
    const desc_start = 1 + num_features * 5;
    for (features.descriptors, 0..) |desc, i| {
        // Convert descriptor bytes to floats for easier JS handling
        for (desc.bits, 0..) |byte, j| {
            result_ptr[desc_start + i * 32 + j] = @floatFromInt(byte);
        }
    }

    return num_features;
}

/// Match features between two images
/// Input format: [num_features1, kp1_data..., desc1_data..., num_features2, kp2_data..., desc2_data...]
/// Output format: [num_matches, idx1_1, idx2_1, distance_1, idx1_2, idx2_2, distance_2, ...]
pub export fn matchFeatures(
    data1_ptr: [*]f32,
    data2_ptr: [*]f32,
    result_ptr: [*]f32,
    max_distance: f32,
) usize {
    const allocator = std.heap.wasm_allocator;

    // Parse first image features
    const num_features1: usize = @intFromFloat(data1_ptr[0]);
    const desc1_start = 1 + num_features1 * 5;

    // Parse second image features
    const num_features2: usize = @intFromFloat(data2_ptr[0]);
    const desc2_start = 1 + num_features2 * 5;

    if (num_features1 == 0 or num_features2 == 0) {
        result_ptr[0] = 0;
        return 0;
    }

    // Reconstruct descriptors
    const descriptors1 = allocator.alloc(zignal.BinaryDescriptor, num_features1) catch |err| {
        std.log.err("Failed to allocate descriptors1: {}", .{err});
        result_ptr[0] = 0;
        return 0;
    };
    defer allocator.free(descriptors1);

    const descriptors2 = allocator.alloc(zignal.BinaryDescriptor, num_features2) catch |err| {
        std.log.err("Failed to allocate descriptors2: {}", .{err});
        result_ptr[0] = 0;
        return 0;
    };
    defer allocator.free(descriptors2);

    // Convert float arrays back to descriptors
    for (0..num_features1) |i| {
        for (0..32) |j| {
            descriptors1[i].bits[j] = @intFromFloat(data1_ptr[desc1_start + i * 32 + j]);
        }
    }

    for (0..num_features2) |i| {
        for (0..32) |j| {
            descriptors2[i].bits[j] = @intFromFloat(data2_ptr[desc2_start + i * 32 + j]);
        }
    }

    // Match features
    const matcher: BruteForceMatcher = .{
        .max_distance = @intFromFloat(max_distance),
        .cross_check = true,
        .ratio_threshold = 0.75, // Add Lowe's ratio test for better matching
    };

    const matches = matcher.match(descriptors1, descriptors2, allocator) catch |err| {
        std.log.err("Failed to match features: {}", .{err});
        result_ptr[0] = 0;
        return 0;
    };
    defer allocator.free(matches);

    // Copy matches to result
    result_ptr[0] = @floatFromInt(matches.len);

    var idx: usize = 1;
    for (matches) |match| {
        result_ptr[idx] = @floatFromInt(match.query_idx);
        result_ptr[idx + 1] = @floatFromInt(match.train_idx);
        result_ptr[idx + 2] = match.distance;
        idx += 3;
    }

    return matches.len;
}

/// Detect and match features between two images in one call
/// Returns matches and keypoints for both images
pub export fn detectAndMatch(
    image1_ptr: [*]Rgba,
    rows1: usize,
    cols1: usize,
    image2_ptr: [*]Rgba,
    rows2: usize,
    cols2: usize,
    result_ptr: [*]f32,
    max_features: usize,
    max_distance: f32,
) usize {
    const allocator = std.heap.wasm_allocator;

    // Process first image
    const img1_size = rows1 * cols1;
    const img1: Image(Rgba) = .initFromSlice(rows1, cols1, image1_ptr[0..img1_size]);

    var gray1 = img1.convert(u8, allocator) catch |err| {
        std.log.err("Failed to convert image1 to grayscale: {}", .{err});
        return 0;
    };
    defer gray1.deinit(allocator);

    // Process second image
    const img2_size = rows2 * cols2;
    const img2: Image(Rgba) = .initFromSlice(rows2, cols2, image2_ptr[0..img2_size]);

    var gray2 = img2.convert(u8, allocator) catch |err| {
        std.log.err("Failed to convert image2 to grayscale: {}", .{err});
        return 0;
    };
    defer gray2.deinit(allocator);

    // Create ORB detector
    var orb: Orb = .{
        .n_features = @intCast(@min(max_features, 500)),
        .scale_factor = 1.2,
        .n_levels = 8,
        .fast_threshold = 20,
    };

    // Detect features in both images
    const features1 = orb.detectAndCompute(gray1, allocator) catch |err| {
        std.log.err("Failed to detect features in image1: {}", .{err});
        return 0;
    };
    defer allocator.free(features1.keypoints);
    defer allocator.free(features1.descriptors);

    const features2 = orb.detectAndCompute(gray2, allocator) catch |err| {
        std.log.err("Failed to detect features in image2: {}", .{err});
        return 0;
    };
    defer allocator.free(features2.keypoints);
    defer allocator.free(features2.descriptors);

    // Match features
    const matcher: BruteForceMatcher = .{
        .max_distance = @intFromFloat(max_distance),
        .cross_check = true,
        .ratio_threshold = 0.75, // Add Lowe's ratio test for better matching
    };

    const matches = matcher.match(features1.descriptors, features2.descriptors, allocator) catch |err| {
        std.log.err("Failed to match features: {}", .{err});
        return 0;
    };
    defer allocator.free(matches);

    // Pack result: [num_kp1, kp1_data..., num_kp2, kp2_data..., num_matches, match_data...]
    var idx: usize = 0;

    // Pack keypoints from image 1
    result_ptr[idx] = @floatFromInt(features1.keypoints.len);
    idx += 1;
    for (features1.keypoints) |kp| {
        result_ptr[idx] = kp.x;
        result_ptr[idx + 1] = kp.y;
        result_ptr[idx + 2] = kp.size;
        result_ptr[idx + 3] = kp.angle;
        result_ptr[idx + 4] = @floatFromInt(kp.octave);
        idx += 5;
    }

    // Pack keypoints from image 2
    result_ptr[idx] = @floatFromInt(features2.keypoints.len);
    idx += 1;
    for (features2.keypoints) |kp| {
        result_ptr[idx] = kp.x;
        result_ptr[idx + 1] = kp.y;
        result_ptr[idx + 2] = kp.size;
        result_ptr[idx + 3] = kp.angle;
        result_ptr[idx + 4] = @floatFromInt(kp.octave);
        idx += 5;
    }

    // Pack matches
    result_ptr[idx] = @floatFromInt(matches.len);
    idx += 1;
    for (matches) |match| {
        result_ptr[idx] = @floatFromInt(match.query_idx);
        result_ptr[idx + 1] = @floatFromInt(match.train_idx);
        result_ptr[idx + 2] = match.distance;
        idx += 3;
    }

    std.log.info("Detected {} and {} features, found {} matches", .{
        features1.keypoints.len,
        features2.keypoints.len,
        matches.len,
    });

    return idx;
}

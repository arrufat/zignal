//! A keypoint represents a distinctive location in an image with associated
//! properties like position, scale, orientation, and response strength.
//! Used for feature detection algorithms like FAST, Harris, and ORB.

const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

/// X coordinate in the image
x: f32,

/// Y coordinate in the image
y: f32,

/// Diameter of the meaningful keypoint neighborhood
size: f32,

/// Computed orientation of the keypoint in degrees [0, 360)
angle: f32,

/// The response by which the keypoint was detected (corner strength)
response: f32,

/// Pyramid octave (level) where the keypoint was detected
/// 0 = original resolution, 1 = half resolution, etc.
octave: i32,

/// Object class ID (for grouped features, -1 if not used)
class_id: i32 = -1,

const KeyPoint = @This();

/// Compare keypoints by response strength (for sorting)
pub fn compareResponse(context: void, a: KeyPoint, b: KeyPoint) bool {
    _ = context;
    return a.response > b.response; // Higher response first
}

/// Compare keypoints by position (for spatial sorting)
pub fn comparePosition(context: void, a: KeyPoint, b: KeyPoint) bool {
    _ = context;
    if (a.y != b.y) return a.y < b.y;
    return a.x < b.x;
}

/// Convert keypoint to scale-space coordinates
pub fn toScaleSpace(self: KeyPoint, scale_factor: f32) KeyPoint {
    const scale = std.math.pow(f32, scale_factor, @as(f32, @floatFromInt(self.octave)));
    return .{
        .x = self.x * scale,
        .y = self.y * scale,
        .size = self.size * scale,
        .angle = self.angle,
        .response = self.response,
        .octave = self.octave,
        .class_id = self.class_id,
    };
}

/// Convert from scale-space to pyramid level coordinates
pub fn fromScaleSpace(self: KeyPoint, scale_factor: f32) KeyPoint {
    const scale = std.math.pow(f32, scale_factor, @as(f32, @floatFromInt(self.octave)));
    return .{
        .x = self.x / scale,
        .y = self.y / scale,
        .size = self.size / scale,
        .angle = self.angle,
        .response = self.response,
        .octave = self.octave,
        .class_id = self.class_id,
    };
}

/// Check if keypoint is within image bounds with margin
pub fn isInBounds(self: KeyPoint, width: usize, height: usize, margin: usize) bool {
    const m = @as(f32, @floatFromInt(margin));
    const w = @as(f32, @floatFromInt(width));
    const h = @as(f32, @floatFromInt(height));

    return self.x >= m and
        self.x < w - m and
        self.y >= m and
        self.y < h - m;
}

/// Compute Euclidean distance to another keypoint
pub fn distance(self: KeyPoint, other: KeyPoint) f32 {
    const dx = self.x - other.x;
    const dy = self.y - other.y;
    return @sqrt(dx * dx + dy * dy);
}

/// Check if two keypoints overlap based on their size
pub fn overlaps(self: KeyPoint, other: KeyPoint, overlap_threshold: f32) bool {
    const dist = self.distance(other);
    const min_size = @min(self.size, other.size);
    return dist < min_size * overlap_threshold;
}

// Tests
test "KeyPoint basic properties" {
    const kp = KeyPoint{
        .x = 100.5,
        .y = 200.3,
        .size = 7.0,
        .angle = 45.0,
        .response = 0.95,
        .octave = 0,
    };

    try expectEqual(@as(f32, 100.5), kp.x);
    try expectEqual(@as(f32, 200.3), kp.y);
    try expectEqual(@as(f32, 7.0), kp.size);
    try expectEqual(@as(f32, 45.0), kp.angle);
    try expectEqual(@as(f32, 0.95), kp.response);
    try expectEqual(@as(i32, 0), kp.octave);
    try expectEqual(@as(i32, -1), kp.class_id);
}

test "KeyPoint scale space conversion" {
    const kp = KeyPoint{
        .x = 100,
        .y = 200,
        .size = 10,
        .angle = 0,
        .response = 1.0,
        .octave = 2,
    };

    const scale_factor = 1.2;
    const scaled = kp.toScaleSpace(scale_factor);

    // At octave 2 with scale factor 1.2: scale = 1.2^2 = 1.44
    try expectApproxEqAbs(@as(f32, 144.0), scaled.x, 0.01);
    try expectApproxEqAbs(@as(f32, 288.0), scaled.y, 0.01);
    try expectApproxEqAbs(@as(f32, 14.4), scaled.size, 0.01);

    // Converting back should give original
    const unscaled = scaled.fromScaleSpace(scale_factor);
    try expectApproxEqAbs(kp.x, unscaled.x, 0.01);
    try expectApproxEqAbs(kp.y, unscaled.y, 0.01);
    try expectApproxEqAbs(kp.size, unscaled.size, 0.01);
}

test "KeyPoint bounds checking" {
    const kp = KeyPoint{
        .x = 50,
        .y = 50,
        .size = 10,
        .angle = 0,
        .response = 1.0,
        .octave = 0,
    };

    try expectEqual(true, kp.isInBounds(100, 100, 10));
    try expectEqual(false, kp.isInBounds(100, 100, 51)); // Too close to edge
    try expectEqual(false, kp.isInBounds(40, 100, 10)); // Out of bounds
}

test "KeyPoint distance and overlap" {
    const kp1 = KeyPoint{
        .x = 100,
        .y = 100,
        .size = 20,
        .angle = 0,
        .response = 1.0,
        .octave = 0,
    };

    const kp2 = KeyPoint{
        .x = 110,
        .y = 100,
        .size = 20,
        .angle = 0,
        .response = 1.0,
        .octave = 0,
    };

    try expectApproxEqAbs(@as(f32, 10.0), kp1.distance(kp2), 0.01);
    try expectEqual(true, kp1.overlaps(kp2, 0.6)); // 10 < 20 * 0.6
    try expectEqual(false, kp1.overlaps(kp2, 0.4)); // 10 >= 20 * 0.4
}

test "KeyPoint sorting" {
    var keypoints = [_]KeyPoint{
        .{ .x = 0, .y = 0, .size = 1, .angle = 0, .response = 0.5, .octave = 0 },
        .{ .x = 0, .y = 0, .size = 1, .angle = 0, .response = 0.9, .octave = 0 },
        .{ .x = 0, .y = 0, .size = 1, .angle = 0, .response = 0.3, .octave = 0 },
    };

    // Sort by response (descending)
    std.mem.sort(KeyPoint, &keypoints, {}, KeyPoint.compareResponse);
    try expectEqual(@as(f32, 0.9), keypoints[0].response);
    try expectEqual(@as(f32, 0.5), keypoints[1].response);
    try expectEqual(@as(f32, 0.3), keypoints[2].response);
}

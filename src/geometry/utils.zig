const Point = @import("Point.zig").Point;
const std = @import("std");

pub const Orientation = enum {
    collinear,
    clockwise,
    counter_clockwise,
};

/// Computes the orientation of three 2D points. Returns clockwise, counter-clockwise,
/// or collinear, accounting for floating-point precision issues.
pub fn computeOrientation(comptime T: type, a: Point(2, T), b: Point(2, T), c: Point(2, T)) Orientation {
    const v: T = a.x() * (b.y() - c.y()) + b.x() * (c.y() - a.y()) + c.x() * (a.y() - b.y());
    const w: T = a.x() * (c.y() - b.y()) + c.x() * (b.y() - a.y()) + b.x() * (a.y() - c.y());
    if (v * w == 0) return .collinear;
    if (v < 0) return .clockwise;
    if (v > 0) return .counter_clockwise;
    return .collinear;
}

/// Returns true when the slice of points contains at least one non-collinear triplet.
pub fn hasNonCollinearTriplet(comptime T: type, points: []const Point(2, T)) bool {
    if (points.len < 3) return false;
    for (0..points.len) |i| {
        for (i + 1..points.len) |j| {
            for (j + 1..points.len) |k| {
                if (computeOrientation(T, points[i], points[j], points[k]) != .collinear) {
                    return true;
                }
            }
        }
    }
    return false;
}

/// Returns true if, and only if, point `p` is inside the triangle `tri`.
/// Uses the barycentric coordinate method.
pub fn pointInTriangle(comptime T: type, p: Point(2, T), tri: [3]Point(2, T)) bool {
    const s = (tri[0].x() - tri[2].x()) * (p.y() - tri[2].y()) - (tri[0].y() - tri[2].y()) * (p.x() - tri[2].x());
    const t = (tri[1].x() - tri[0].x()) * (p.y() - tri[0].y()) - (tri[1].y() - tri[0].y()) * (p.x() - tri[0].x());

    if ((s < 0) != (t < 0) and s != 0 and t != 0)
        return false;

    const d = (tri[2].x() - tri[1].x()) * (p.y() - tri[1].y()) - (tri[2].y() - tri[1].y()) * (p.x() - tri[1].x());
    return d == 0 or (d < 0) == (s + t < 0);
}

/// Returns the barycenter (geometric centroid) of the triangle.
pub fn findBarycenter(comptime T: type, triangle: [3]Point(2, T)) Point(2, T) {
    return .init(.{
        (triangle[0].x() + triangle[1].x() + triangle[2].x()) / 3,
        (triangle[0].y() + triangle[1].y() + triangle[2].y()) / 3,
    });
}

test "computeOrientation" {
    const orientationFn = computeOrientation;
    const a: Point(2, f32) = .init(.{ 4.9171928e-1, 6.473901e-1 });
    const b: Point(2, f32) = .init(.{ 3.6271343e-1, 9.712454e-1 });
    const c: Point(2, f32) = .init(.{ 3.9276862e-1, 8.9579517e-1 });
    const orientation_abc = orientationFn(f32, a, b, c);
    const orientation_acb = orientationFn(f32, a, c, b);
    try std.testing.expectEqual(orientation_abc, orientation_acb);
}

test "hasNonCollinearTriplet" {
    const pts_collinear: []const Point(2, f32) = &.{
        .init(.{ 0, 0 }),
        .init(.{ 1, 1 }),
        .init(.{ 2, 2 }),
        .init(.{ 3, 3 }),
    };
    try std.testing.expect(!hasNonCollinearTriplet(f32, pts_collinear));

    const pts_non_collinear: []const Point(2, f32) = &.{
        .init(.{ 0, 0 }),
        .init(.{ 1, 0 }),
        .init(.{ 0, 1 }),
    };
    try std.testing.expect(hasNonCollinearTriplet(f32, pts_non_collinear));
}

test "pointInTriangle" {
    const tri = [_]Point(2, f32){
        .init(.{ 0, 0 }),
        .init(.{ 2, 0 }),
        .init(.{ 1, 2 }),
    };
    var p: Point(2, f32) = .init(.{ 1, 1 });
    try std.testing.expect(pointInTriangle(f32, p, tri));

    p = .init(.{ 3, 1 });
    try std.testing.expect(!pointInTriangle(f32, p, tri));

    p = .init(.{ 1, 0 });
    try std.testing.expect(pointInTriangle(f32, p, tri));

    p = .init(.{ 0, 0 });
    try std.testing.expect(pointInTriangle(f32, p, tri));
}

test "findBarycenter" {
    var tri = [_]Point(2, f32){
        .init(.{ 0, 0 }),
        .init(.{ 2, 0 }),
        .init(.{ 1, 2 }),
    };
    var barycenter = findBarycenter(f32, tri);
    try std.testing.expectEqual(barycenter, Point(2, f32).init(.{ 1, 2.0 / 3.0 }));

    tri = .{
        .init(.{ -1, -1 }),
        .init(.{ 1, -1 }),
        .init(.{ 0, 2 }),
    };
    barycenter = findBarycenter(f32, tri);
    try std.testing.expectEqual(barycenter, Point(2, f32).init(.{ 0, 0 }));
}

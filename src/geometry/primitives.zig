const std = @import("std");
const expect = std.testing.expect;
const expectEqualDeep = std.testing.expectEqualDeep;

const Point2d = @import("Point.zig").Point2d;

/// Returns true if, and only if, point `p` is inside the triangle `tri`.
/// Uses the barycentric coordinate method.
pub fn pointInTriangle(comptime T: type, p: Point2d(T), tri: [3]Point2d(T)) bool {
    const s = (tri[0].x() - tri[2].x()) * (p.y() - tri[2].y()) - (tri[0].y() - tri[2].y()) * (p.x() - tri[2].x());
    const t = (tri[1].x() - tri[0].x()) * (p.y() - tri[0].y()) - (tri[1].y() - tri[0].y()) * (p.x() - tri[0].x());

    if ((s < 0) != (t < 0) and s != 0 and t != 0)
        return false;

    const d = (tri[2].x() - tri[1].x()) * (p.y() - tri[1].y()) - (tri[2].y() - tri[1].y()) * (p.x() - tri[1].x());
    return d == 0 or (d < 0) == (s + t < 0);
}

/// Returns the barycenter (geometric centroid) of the triangle.
pub fn findBarycenter(comptime T: type, triangle: [3]Point2d(T)) Point2d(T) {
    return Point2d(T).init2d(
        (triangle[0].x() + triangle[1].x() + triangle[2].x()) / 3,
        (triangle[0].y() + triangle[1].y() + triangle[2].y()) / 3,
    );
}

test "pointInTriangle" {
    // Test case 1: Point inside triangle.
    const tri = [_]Point2d(f32){
        Point2d(f32).init2d(0, 0),
        Point2d(f32).init2d(2, 0),
        Point2d(f32).init2d(1, 2),
    };
    var p: Point2d(f32) = Point2d(f32).init2d(1, 1);
    try expect(pointInTriangle(f32, p, tri));

    // Test case 2: Point outside triangle.
    p = Point2d(f32).init2d(3, 1);
    try expect(!pointInTriangle(f32, p, tri));

    // Test case 3: Point on edge.
    p = Point2d(f32).init2d(1, 0);
    try expect(pointInTriangle(f32, p, tri));

    // Test case 4: Point exactly at vertex.
    p = Point2d(f32).init2d(0, 0);
    try expect(pointInTriangle(f32, p, tri));
}

test "findBarycenter" {
    // Test case 1: Simple triangle.
    var tri = [_]Point2d(f32){
        Point2d(f32).init2d(0, 0),
        Point2d(f32).init2d(2, 0),
        Point2d(f32).init2d(1, 2),
    };
    var barycenter = findBarycenter(f32, tri);
    try expectEqualDeep(barycenter, Point2d(f32).init2d(1, 2.0 / 3.0));

    // Test case 2: Another triangle to ensure precision.
    tri = .{
        Point2d(f32).init2d(-1, -1),
        Point2d(f32).init2d(1, -1),
        Point2d(f32).init2d(0, 2),
    };
    barycenter = findBarycenter(f32, tri);
    try expectEqualDeep(barycenter, Point2d(f32).init2d(0, 0));
}

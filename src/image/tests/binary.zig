const std = @import("std");
const testing = std.testing;
const Image = @import("../../image.zig").Image;
const BinaryKernel = @import("../../image.zig").BinaryKernel;

test "threshold otsu binarizes bimodal image" {
    var data = [_]u8{ 10, 10, 10, 10, 200, 200, 200, 200 };
    const image = Image(u8).initFromSlice(2, 4, data[0..]);

    var out: Image(u8) = Image(u8).empty;
    defer if (out.data.len != 0) out.deinit(testing.allocator);

    const threshold = try image.thresholdOtsu(testing.allocator, &out);

    try testing.expect(threshold >= 5 and threshold <= 50);

    for (0..2) |r| {
        for (0..4) |c| {
            const expected: u8 = if (r == 0) 0 else 255;
            try testing.expectEqual(expected, out.at(r, c).*);
        }
    }
}

test "adaptive mean threshold isolates bright center" {
    var data = [_]u8{
        50, 50,  50,
        50, 200, 50,
        50, 50,  50,
    };
    const image = Image(u8).initFromSlice(3, 3, data[0..]);

    var out: Image(u8) = Image(u8).empty;
    defer if (out.data.len != 0) out.deinit(testing.allocator);

    try image.thresholdAdaptiveMean(testing.allocator, 1, 10.0, &out);

    for (0..3) |r| {
        for (0..3) |c| {
            const expected: u8 = if (r == 1 and c == 1) 255 else 0;
            try testing.expectEqual(expected, out.at(r, c).*);
        }
    }
}

test "adaptive mean threshold rejects zero radius" {
    var data = [_]u8{
        10, 20,
        30, 40,
    };
    const image = Image(u8).initFromSlice(2, 2, data[0..]);

    var out: Image(u8) = Image(u8).empty;
    defer if (out.data.len != 0) out.deinit(testing.allocator);

    try testing.expectError(error.InvalidRadius, image.thresholdAdaptiveMean(testing.allocator, 0, 0.0, &out));
}

test "binary dilation expands single pixel" {
    var data = [_]u8{
        0, 0, 0,   0, 0,
        0, 0, 0,   0, 0,
        0, 0, 255, 0, 0,
        0, 0, 0,   0, 0,
        0, 0, 0,   0, 0,
    };
    const image = Image(u8).initFromSlice(5, 5, data[0..]);

    var out: Image(u8) = Image(u8).empty;
    defer if (out.data.len != 0) out.deinit(testing.allocator);

    const kernel = BinaryKernel.init(3, 3, &[_]u8{
        1, 1, 1,
        1, 1, 1,
        1, 1, 1,
    });

    try image.dilateBinary(testing.allocator, kernel, 1, &out);

    for (0..5) |r| {
        for (0..5) |c| {
            const dist_row = @abs(@as(i32, @intCast(r)) - 2);
            const dist_col = @abs(@as(i32, @intCast(c)) - 2);
            const expected: u8 = if (dist_row <= 1 and dist_col <= 1) 255 else 0;
            try testing.expectEqual(expected, out.at(r, c).*);
        }
    }
}

test "binary open removes isolated noise" {
    var data = [_]u8{
        0, 0,   0,   0,   0,
        0, 255, 255, 255, 255,
        0, 255, 255, 255, 0,
        0, 255, 255, 255, 0,
        0, 0,   0,   0,   0,
    };
    var image = Image(u8).initFromSlice(5, 5, data[0..]);

    const kernel = BinaryKernel.init(3, 3, &[_]u8{
        1, 1, 1,
        1, 1, 1,
        1, 1, 1,
    });

    try image.openBinary(testing.allocator, kernel, 1, &image);

    for (0..5) |r| {
        for (0..5) |c| {
            const expected: u8 = if (r >= 1 and r <= 3 and c >= 1 and c <= 3) 255 else 0;
            try testing.expectEqual(expected, image.at(r, c).*);
        }
    }
}

test "binary close fills holes" {
    var data = [_]u8{
        0, 0,   0,   0,   0,
        0, 255, 255, 255, 0,
        0, 255, 0,   255, 0,
        0, 255, 255, 255, 0,
        0, 0,   0,   0,   0,
    };
    var image = Image(u8).initFromSlice(5, 5, data[0..]);

    const kernel = BinaryKernel.init(3, 3, &[_]u8{
        1, 1, 1,
        1, 1, 1,
        1, 1, 1,
    });

    try image.closeBinary(testing.allocator, kernel, 1, &image);

    for (0..5) |r| {
        for (0..5) |c| {
            const expected: u8 = if (r >= 1 and r <= 3 and c >= 1 and c <= 3) 255 else 0;
            try testing.expectEqual(expected, image.at(r, c).*);
        }
    }
}

test "binary erosion shrinks block across iterations" {
    var data = [_]u8{
        255, 255, 255, 255, 255,
        255, 255, 255, 255, 255,
        255, 255, 255, 255, 255,
        255, 255, 255, 255, 255,
        255, 255, 255, 255, 255,
    };
    const image = Image(u8).initFromSlice(5, 5, data[0..]);

    var out: Image(u8) = Image(u8).empty;
    defer if (out.data.len != 0) out.deinit(testing.allocator);

    const kernel = BinaryKernel.init(3, 3, &[_]u8{
        1, 1, 1,
        1, 1, 1,
        1, 1, 1,
    });

    try image.erodeBinary(testing.allocator, kernel, 2, &out);

    for (0..5) |r| {
        for (0..5) |c| {
            const expected: u8 = if (r == 2 and c == 2) 255 else 0;
            try testing.expectEqual(expected, out.at(r, c).*);
        }
    }
}

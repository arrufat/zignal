//! Flood Fill Tests

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const Image = @import("../../image.zig").Image;
const color = @import("../../color.zig");
const Rgb = color.Rgb(u8);

test "flood fill connectivity" {
    const allocator = std.testing.allocator;

    // Create a 5x5 image where we have a cross pattern of 5s and one diagonal element.
    // Row 0: 0 5 0 0 0
    // Row 1: 0 0 5 0 0
    // Row 2: 5 5 5 5 5
    // Row 3: 0 0 5 0 0
    // Row 4: 0 0 5 0 0
    var img = try Image(u8).init(allocator, 5, 5);
    defer img.deinit(allocator);
    img.fill(0);

    img.at(0, 1).* = 5;
    img.at(1, 2).* = 5;
    img.at(2, 0).* = 5;
    img.at(2, 1).* = 5;
    img.at(2, 2).* = 5;
    img.at(2, 3).* = 5;
    img.at(2, 4).* = 5;
    img.at(3, 2).* = 5;
    img.at(4, 2).* = 5;

    // Duplicate for 4-connectivity test
    var img4 = try img.dupe(allocator);
    defer img4.deinit(allocator);

    // Duplicate for 8-connectivity test
    var img8 = try img.dupe(allocator);
    defer img8.deinit(allocator);

    // Under 4-connectivity, starting at (2,2) should fill all 5s except (0,1)
    // because (0,1) is only diagonally connected to (1,2).
    try img4.floodFill(allocator, 2, 2, 9, .{ .threshold = 0.0, .connectivity = .four });
    try expectEqual(@as(u8, 5), img4.at(0, 1).*); // Unfilled
    try expectEqual(@as(u8, 9), img4.at(1, 2).*); // Filled
    try expectEqual(@as(u8, 9), img4.at(2, 2).*); // Filled

    // Under 8-connectivity, starting at (2,2) should fill all 5s including (0,1)
    try img8.floodFill(allocator, 2, 2, 9, .{ .threshold = 0.0, .connectivity = .eight });
    try expectEqual(@as(u8, 9), img8.at(0, 1).*); // Filled via diagonal connection
    try expectEqual(@as(u8, 9), img8.at(1, 2).*); // Filled
    try expectEqual(@as(u8, 9), img8.at(2, 2).*); // Filled
}

test "flood fill relative threshold modes" {
    const allocator = std.testing.allocator;

    // Create a 1x5 gradient image: [0, 1, 2, 3, 4]
    // Under seed (threshold=1.0, seed=0):
    // - neighbor 1 (value 1): diff to seed 0 is 1.0 <= 1.0 (fills)
    // - neighbor 2 (value 2): diff to seed 0 is 2.0 > 1.0 (does not fill)
    // Results: [9, 9, 2, 3, 4]
    //
    // Under neighbor (threshold=1.0, seed=0):
    // - neighbor 1 (value 1): diff to parent 0 is 1.0 <= 1.0 (fills)
    // - neighbor 2 (value 2): diff to parent 1 is 1.0 <= 1.0 (fills)
    // - neighbor 3 (value 3): diff to parent 2 is 1.0 <= 1.0 (fills)
    // - neighbor 4 (value 4): diff to parent 3 is 1.0 <= 1.0 (fills)
    // Results: [9, 9, 9, 9, 9]

    var img_seed = try Image(u8).init(allocator, 1, 5);
    defer img_seed.deinit(allocator);
    for (0..5) |c| {
        img_seed.at(0, c).* = @intCast(c);
    }

    var img_parent = try img_seed.dupe(allocator);
    defer img_parent.deinit(allocator);

    // Test seed relative
    try img_seed.floodFill(allocator, 0, 0, 9, .{ .threshold = 1.0, .mode = .seed });
    try expectEqual(@as(u8, 9), img_seed.at(0, 0).*);
    try expectEqual(@as(u8, 9), img_seed.at(0, 1).*);
    try expectEqual(@as(u8, 2), img_seed.at(0, 2).*);
    try expectEqual(@as(u8, 3), img_seed.at(0, 3).*);
    try expectEqual(@as(u8, 4), img_seed.at(0, 4).*);

    // Test parent relative
    try img_parent.floodFill(allocator, 0, 0, 9, .{ .threshold = 1.0, .mode = .neighbor });
    try expectEqual(@as(u8, 9), img_parent.at(0, 0).*);
    try expectEqual(@as(u8, 9), img_parent.at(0, 1).*);
    try expectEqual(@as(u8, 9), img_parent.at(0, 2).*);
    try expectEqual(@as(u8, 9), img_parent.at(0, 3).*);
    try expectEqual(@as(u8, 9), img_parent.at(0, 4).*);
}

test "flood fill RGB color images" {
    const allocator = std.testing.allocator;

    var img = try Image(Rgb).init(allocator, 1, 3);
    defer img.deinit(allocator);

    img.at(0, 0).* = .{ .r = 100, .g = 100, .b = 100 };
    img.at(0, 1).* = .{ .r = 100, .g = 100, .b = 103 }; // Dist = 3
    img.at(0, 2).* = .{ .r = 100, .g = 100, .b = 107 }; // Dist = 7 (from seed)

    const fill_val = Rgb{ .r = 255, .g = 0, .b = 0 };

    // Duplicate for threshold 4.0 (should fill index 0 and 1, but not 2)
    var img_4 = try img.dupe(allocator);
    defer img_4.deinit(allocator);

    try img_4.floodFill(allocator, 0, 0, fill_val, .{ .threshold = 4.0 });
    try expectEqual(fill_val, img_4.at(0, 0).*);
    try expectEqual(fill_val, img_4.at(0, 1).*);
    try expectEqual(Rgb{ .r = 100, .g = 100, .b = 107 }, img_4.at(0, 2).*);

    // Duplicate for threshold 8.0 (should fill all index 0, 1, and 2)
    var img_8 = try img.dupe(allocator);
    defer img_8.deinit(allocator);

    try img_8.floodFill(allocator, 0, 0, fill_val, .{ .threshold = 8.0 });
    try expectEqual(fill_val, img_8.at(0, 0).*);
    try expectEqual(fill_val, img_8.at(0, 1).*);
    try expectEqual(fill_val, img_8.at(0, 2).*);
}

test "flood fill error bounds" {
    const allocator = std.testing.allocator;

    var img = try Image(u8).init(allocator, 3, 3);
    defer img.deinit(allocator);

    // Start coordinates out of bounds
    const res = img.floodFill(allocator, 3, 3, 9, .{ .threshold = 1.0 });
    try std.testing.expectError(error.OutOfBounds, res);
}

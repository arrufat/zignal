//! Iterator for all pixels in an image, handles views transparently.

const std = @import("std");
const Image = @import("image.zig").Image;
const Rectangle = @import("../geometry.zig").Rectangle;

pub fn PixelIterator(comptime T: type) type {
    return struct {
        data: []T,
        cols: usize,
        stride: usize,
        rows: usize,
        current_row: usize = 0,
        current_col: usize = 0,

        const Self = @This();

        /// Initializes the iterator from an image, resetting iteration state.
        pub fn init(self: *Self, image: Image(T)) void {
            self.data = image.data;
            self.cols = image.cols;
            self.stride = image.stride;
            self.rows = image.rows;
            self.current_row = 0;
            self.current_col = 0;
        }

        /// Returns a pointer to the current pixel, or null if iteration is
        /// complete, and advances to the next pixel.
        pub fn next(self: *Self) ?*T {
            if (self.current_row >= self.rows) return null;

            const index = self.current_row * self.stride + self.current_col;
            const ptr = &self.data[index];

            self.current_col += 1;
            if (self.current_col >= self.cols) {
                self.current_col = 0;
                self.current_row += 1;
            }

            return ptr;
        }

        /// Returns the current pixel without advancing the iterator.
        pub fn peek(self: Self) ?*T {
            if (self.current_row >= self.rows) return null;

            const index = self.current_row * self.stride + self.current_col;
            return &self.data[index];
        }

        /// Resets the iterator to the beginning.
        pub fn reset(self: *Self) void {
            self.current_row = 0;
            self.current_col = 0;
        }
    };
}

test "PixelIterator basic functionality" {
    const allocator = std.testing.allocator;

    // Create a simple 3x3 image
    var img = try Image(u8).initAlloc(allocator, 3, 3);
    defer img.deinit(allocator);

    // Fill with sequential values
    for (0..9) |i| {
        img.data[i] = @intCast(i);
    }

    // Test basic iteration
    var pixel_iter = img.pixels();
    var pixel_count: usize = 0;
    while (pixel_iter.next()) |pixel| {
        try std.testing.expectEqual(@as(u8, @intCast(pixel_count)), pixel.*);
        pixel_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 9), pixel_count);

    // Test peek()
    pixel_iter.reset();
    try std.testing.expectEqual(@as(u8, 0), pixel_iter.peek().?.*);
    try std.testing.expectEqual(@as(u8, 0), pixel_iter.next().?.*);
    try std.testing.expectEqual(@as(u8, 1), pixel_iter.peek().?.*);
    try std.testing.expectEqual(@as(u8, 1), pixel_iter.peek().?.*); // peek doesn't advance
    try std.testing.expectEqual(@as(u8, 1), pixel_iter.next().?.*);

    // Test reset()
    pixel_iter.reset();
    try std.testing.expectEqual(@as(u8, 0), pixel_iter.next().?.*);
}

test "PixelIterator with views" {
    const allocator = std.testing.allocator;

    // Create a 4x4 image
    var img: Image(u8) = try .initAlloc(allocator, 4, 4);
    defer img.deinit(allocator);

    // Fill with sequential values
    for (0..16) |i| {
        img.data[i] = @intCast(i);
    }

    // Create a view (2x2 from position 1,1)
    const view = img.view(Rectangle(usize){ .l = 1, .t = 1, .r = 2, .b = 2 });

    // Test that view is indeed a view
    try std.testing.expect(view.isView());

    // Verify view dimensions
    try std.testing.expectEqual(@as(usize, 2), view.rows);
    try std.testing.expectEqual(@as(usize, 2), view.cols);
    try std.testing.expectEqual(@as(usize, 4), view.stride);

    // Test pixel iterator on view
    var pixel_iter = view.pixels();
    const expected = [_]u8{ 5, 6, 9, 10 };
    var pixel_count: usize = 0;

    while (pixel_iter.next()) |pixel| {
        try std.testing.expectEqual(expected[pixel_count], pixel.*);
        pixel_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), pixel_count);

    // Test peek() on view
    pixel_iter.reset();
    try std.testing.expectEqual(@as(u8, 5), pixel_iter.peek().?.*);
    _ = pixel_iter.next();
    try std.testing.expectEqual(@as(u8, 6), pixel_iter.peek().?.*);

    // Test reset() on view
    pixel_iter.reset();
    try std.testing.expectEqual(@as(u8, 5), pixel_iter.next().?.*);
}

test "PixelIterator reuse with init" {
    const allocator = std.testing.allocator;

    // Create two different images
    var img1: Image(u8) = try .initAlloc(allocator, 2, 2);
    defer img1.deinit(allocator);
    for (0..4) |i| {
        img1.data[i] = @intCast(i * 10); // 0, 10, 20, 30
    }

    var img2: Image(u8) = try .initAlloc(allocator, 3, 3);
    defer img2.deinit(allocator);
    for (0..9) |i| {
        img2.data[i] = @intCast(i); // 0, 1, 2, ..., 8
    }

    // Create a single iterator
    var iter: PixelIterator(u8) = undefined;

    // Use it for the first image
    iter.init(img1);
    var count: usize = 0;
    while (iter.next()) |pixel| : (count += 1) {
        try std.testing.expectEqual(@as(u8, @intCast(count * 10)), pixel.*);
    }
    try std.testing.expectEqual(@as(usize, 4), count);

    // Reuse the same iterator for the second image
    iter.init(img2);
    count = 0;
    while (iter.next()) |pixel| : (count += 1) {
        try std.testing.expectEqual(@as(u8, @intCast(count)), pixel.*);
    }
    try std.testing.expectEqual(@as(usize, 9), count);

    // Verify we can still use it with views
    const view = img2.view(Rectangle(usize){ .l = 1, .t = 1, .r = 2, .b = 2 });
    iter.init(view);
    const expected = [_]u8{ 4, 5, 7, 8 };
    count = 0;
    while (iter.next()) |pixel| : (count += 1) {
        try std.testing.expectEqual(expected[count], pixel.*);
    }
    try std.testing.expectEqual(@as(usize, 4), count);
}

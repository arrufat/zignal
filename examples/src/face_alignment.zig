const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const zignal = @import("zignal");
const Point2d = zignal.Point2d(f32);
const Image = zignal.Image;
const SimilarityTransform = zignal.SimilarityTransform(f32);
const Rectangle = zignal.Rectangle(f32);
const Rgba = zignal.Rgba;
const drawRectangle = zignal.drawRectangle;

pub const std_options: std.Options = .{
    .logFn = if (builtin.cpu.arch.isWasm()) @import("js.zig").logFn else std.log.defaultLog,
    .log_level = std.log.default_level,
};

pub fn panic(msg: []const u8, st: ?*std.builtin.StackTrace, addr: ?usize) noreturn {
    _ = st;
    _ = addr;
    std.log.err("panic: {s}", .{msg});
    @trap();
}

/// These landmarks correspond to the closest to dlib's 5 alignment landmarks.
/// For more information check dlib's blog.
/// https://blog.dlib.net/2017/09/fast-multiclass-object-detection-in.html
pub const alignment: []const usize = &.{ 263, 398, 33, 173, 2 };

/// Extracts the aligned face contained in image using landmarks.
pub fn extractAlignedFace(
    comptime T: type,
    allocator: std.mem.Allocator,
    image: Image(T),
    landmarks: []const Point2d,
    padding: f32,
    blurring: i32,
    out: *Image(T),
) !void {
    // This are the normalized coordinates of the aligned landmarks
    // taken from dlib.
    var from_points: [5]Point2d = .{
        .{ .x = 0.8595674595992, .y = 0.2134981538014 },
        .{ .x = 0.6460604764104, .y = 0.2289674387677 },
        .{ .x = 0.1205750620789, .y = 0.2137274526848 },
        .{ .x = 0.3340850613712, .y = 0.2290642403242 },
        .{ .x = 0.4901123135679, .y = 0.6277975316475 },
    };

    const to_points: [5]Point2d = .{
        landmarks[alignment[0]].scale(image.cols, image.rows),
        landmarks[alignment[1]].scale(image.cols, image.rows),
        landmarks[alignment[2]].scale(image.cols, image.rows),
        landmarks[alignment[3]].scale(image.cols, image.rows),
        landmarks[alignment[4]].scale(image.cols, image.rows),
    };
    assert(from_points.len == to_points.len);
    assert(out.cols == out.rows);
    assert(out.cols > 0);
    const side: f32 = @floatFromInt(out.cols);
    for (&from_points) |*p| {
        p.x = (padding + p.x) / (2 * padding + 1) * side;
        p.y = (padding + p.y) / (2 * padding + 1) * side;
    }
    const transform = SimilarityTransform.find(&from_points, &to_points);
    var p = transform.project(.{ .x = 1, .y = 0 });
    p.x -= transform.bias.at(0, 0);
    p.y -= transform.bias.at(1, 0);
    const angle = std.math.atan2(p.y, p.x);
    const scale = p.norm();
    const center = transform.project(.{ .x = side / 2, .y = side / 2 });
    var rotated: Image(Rgba) = undefined;
    try image.rotateFrom(allocator, center, angle, &rotated);
    defer rotated.deinit(allocator);

    const rect = Rectangle.initCenter(center.x, center.y, side * scale, side * scale);
    drawRectangle(Rgba, image, rect, 1, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    var chip: Image(Rgba) = undefined;
    try rotated.crop(allocator, rect, &chip);
    defer chip.deinit(allocator);

    var resized = try Image(Rgba).initAlloc(allocator, out.rows, out.cols);
    defer resized.deinit(allocator);
    chip.resize(&resized);
    for (out.data, resized.data) |*c, b| {
        c.* = b;
    }

    if (blurring > 0) {
        try out.boxBlur(allocator, out, @intCast(blurring));
    } else if (blurring < 0) {
        try out.sharpen(allocator, out, @intCast(-blurring));
    }
}

pub export fn extract_aligned_face(
    rgba_ptr: [*]Rgba,
    rows: usize,
    cols: usize,
    out_ptr: [*]Rgba,
    out_rows: usize,
    out_cols: usize,
    padding: f32,
    blurring: i32,
    landmarks_ptr: [*]const Point2d,
    landmarks_len: usize,
    extra_ptr: ?[*]u8,
    extra_len: usize,
) void {
    var arena = std.heap.ArenaAllocator.init(blk: {
        if (builtin.cpu.arch.isWasm() and builtin.os.tag == .freestanding) {
            // We need at least one Image(Rgba) for blurring and one Image(f32) for the integral image.
            assert(extra_len >= 8 * rows * cols);
            if (extra_ptr) |ptr| {
                var fba = std.heap.FixedBufferAllocator.init(ptr[0..extra_len]);
                break :blk fba.allocator();
            } else {
                @panic("ERROR: extra_ptr can't be null when running in WebAssembly.");
            }
        } else {
            break :blk std.heap.page_allocator;
        }
    });
    defer arena.deinit();
    const allocator = arena.allocator();

    const image: Image(Rgba) = .{
        .rows = rows,
        .cols = cols,
        .data = rgba_ptr[0 .. rows * cols],
    };

    const landmarks: []Point2d = blk: {
        var array = std.ArrayList(Point2d).init(allocator);
        array.resize(landmarks_len) catch {
            std.log.err("Ran out of memory while resizing landmarks ArrayList", .{});
            @panic("OOM");
        };
        for (array.items, 0..) |*l, i| {
            l.* = landmarks_ptr[i];
        }
        break :blk array.toOwnedSlice() catch {
            std.log.err("Ran out of memory while taking ownership of the landmarks ArrayList", .{});
            @panic("OOM");
        };
    };
    defer allocator.free(landmarks);

    var aligned: Image(Rgba) = .{
        .rows = out_rows,
        .cols = out_cols,
        .data = out_ptr[0 .. out_rows * out_cols],
    };
    extractAlignedFace(Rgba, allocator, image, landmarks, padding, blurring, &aligned) catch {
        std.log.err("Ran out of memory while extracting the aligned face", .{});
        @panic("OOM");
    };
}

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

const zignal = @import("zignal");
const Image = zignal.Image;
const Rgba = zignal.Rgba;
const Hsv = zignal.Hsv;
const Canvas = zignal.Canvas;

const Point2d = zignal.Point2d(f32);
const SimilarityTransform = zignal.SimilarityTransform(f32);
const Rectangle = zignal.Rectangle(f32);

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
    // These are the normalized coordinates of the aligned landmarks
    // taken from dlib.
    var from_points: [5]Point2d = .{
        Point2d.init2d(0.8595674595992, 0.2134981538014),
        Point2d.init2d(0.6460604764104, 0.2289674387677),
        Point2d.init2d(0.1205750620789, 0.2137274526848),
        Point2d.init2d(0.3340850613712, 0.2290642403242),
        Point2d.init2d(0.4901123135679, 0.6277975316475),
    };
    const fcols: f32 = @floatFromInt(image.cols);
    const frows: f32 = @floatFromInt(image.rows);

    // These are the detected points from MediaPipe.
    const to_points: [5]Point2d = .{
        landmarks[alignment[0]].scaleEach(.{ fcols, frows }),
        landmarks[alignment[1]].scaleEach(.{ fcols, frows }),
        landmarks[alignment[2]].scaleEach(.{ fcols, frows }),
        landmarks[alignment[3]].scaleEach(.{ fcols, frows }),
        landmarks[alignment[4]].scaleEach(.{ fcols, frows }),
    };
    assert(from_points.len == to_points.len);
    assert(out.cols == out.rows);
    assert(out.cols > 0);
    const side: f32 = @floatFromInt(out.cols);
    for (&from_points) |*p| {
        p.* = Point2d.init2d((padding + p.x()) / (2 * padding + 1) * side, (padding + p.y()) / (2 * padding + 1) * side);
    }

    // Find the transforms that maps the points between the canonical landmarks
    // and the detected landmarks.
    const transform: SimilarityTransform = .init(&from_points, &to_points);
    const p = transform.project(Point2d.init2d(1, 0)).sub(transform.bias.toPoint2d());
    const angle = std.math.atan2(p.y(), p.x());
    const scale = p.norm();
    const center = transform.project(Point2d.init2d(side / 2, side / 2));

    // Rotate the image first to align the face.
    var rotated: Image(Rgba) = .empty;
    try image.rotateAround(allocator, center, angle, &rotated);
    defer rotated.deinit(allocator);

    // Draw the rectangle on the input image.
    var rect: Rectangle = .initCenter(center.x(), center.y(), side * scale, side * scale);
    const canvas: Canvas(T) = .init(allocator, image);
    canvas.drawRectangle(rect, Hsv{ .h = 0, .s = 100, .v = 100 }, 1, .fast);

    // Calculate where the center point ended up in the rotated image.
    const offset = Point2d.init2d((@as(f32, @floatFromInt(rotated.cols)) - fcols) / 2, (@as(f32, @floatFromInt(rotated.rows)) - frows) / 2);

    // Adjust the rectangle to crop from the rotated image (it has been resized not to be clipped).
    rect = .initCenter(center.x() + offset.x(), center.y() + offset.y(), side * scale, side * scale);
    var chip: Image(Rgba) = .empty;
    try rotated.crop(allocator, rect, &chip);
    defer chip.deinit(allocator);

    // Resize to the desired size
    var resized: Image(Rgba) = try .initAlloc(allocator, out.rows, out.cols);
    defer resized.deinit(allocator);
    chip.resize(resized, .bilinear);
    for (out.data, resized.data) |*c, b| {
        c.* = b;
    }

    // Perform blurring or sharpening to the aligned face.
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
    var arena: std.heap.ArenaAllocator = .init(blk: {
        if (builtin.cpu.arch.isWasm() and builtin.os.tag == .freestanding) {
            // We need at least one Image(Rgba) for blurring and one Image(f32) for the integral image.
            assert(extra_len >= 9 * rows * cols);
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

    const image: Image(Rgba) = .init(rows, cols, rgba_ptr[0 .. rows * cols]);

    const landmarks: []Point2d = blk: {
        var array: std.ArrayList(Point2d) = .init(allocator);
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

    var aligned = Image(Rgba).init(out_rows, out_cols, out_ptr[0 .. out_rows * out_cols]);
    extractAlignedFace(Rgba, allocator, image, landmarks, padding, blurring, &aligned) catch {
        std.log.err("Ran out of memory while extracting the aligned face", .{});
        @panic("OOM");
    };
}

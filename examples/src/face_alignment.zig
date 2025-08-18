const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

const zignal = @import("zignal");
const Image = zignal.Image;
const Rgba = zignal.Rgba;
const Hsv = zignal.Hsv;
const Canvas = zignal.Canvas;

const Point = zignal.Point(2, f32);
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
    landmarks: []const Point,
    padding: f32,
    blurring: i32,
    out: *Image(T),
) !void {
    // These are the normalized coordinates of the aligned landmarks taken from dlib.
    var from_points: [5]Point = .{
        .point(.{ 0.8595674595992, 0.2134981538014 }),
        .point(.{ 0.6460604764104, 0.2289674387677 }),
        .point(.{ 0.1205750620789, 0.2137274526848 }),
        .point(.{ 0.3340850613712, 0.2290642403242 }),
        .point(.{ 0.4901123135679, 0.6277975316475 }),
    };
    const fcols: f32 = @floatFromInt(image.cols);
    const frows: f32 = @floatFromInt(image.rows);

    // These are the detected points from MediaPipe.
    const to_points: [5]Point = .{
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
    for (&from_points) |*p| p.* = .point(.{
        (padding + p.x()) / (2 * padding + 1) * side,
        (padding + p.y()) / (2 * padding + 1) * side,
    });

    // Find the transforms that maps the points between the canonical landmarks and the
    // detected landmarks.
    const transform: SimilarityTransform = .init(&from_points, &to_points);

    // For each pixel in the output, find its source using the transform
    for (0..out.rows) |r| {
        for (0..out.cols) |c| {
            // Current pixel in output space
            const out_point: Point = .point(.{ @as(f32, @floatFromInt(c)), @as(f32, @floatFromInt(r)) });

            // Transform to source image space
            const src_point = transform.project(out_point);

            // Sample from source image with interpolation
            out.at(r, c).* = image.interpolate(src_point.x(), src_point.y(), .bilinear) orelse std.mem.zeroes(T);
        }
    }

    // Perform blurring or sharpening to the aligned face.
    if (blurring > 0) {
        try out.blurBox(allocator, out, @intCast(blurring));
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
    landmarks_ptr: [*]const Point,
    landmarks_len: usize,
    extra_ptr: ?[*]u8,
    extra_len: usize,
) void {
    var arena: std.heap.ArenaAllocator = .init(blk: {
        if (builtin.cpu.arch.isWasm() and builtin.os.tag == .freestanding) {
            // We need at least one Image(Rgba) for blurring and one Image(f32) for the integral image.
            assert(extra_len >= 9 * rows * cols);
            if (extra_ptr) |ptr| {
                var fba: std.heap.FixedBufferAllocator = .init(ptr[0..extra_len]);
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

    const landmarks: []const Point = blk: {
        var array: std.ArrayList(Point) = .empty;
        array.resize(allocator, landmarks_len) catch {
            std.log.err("Ran out of memory while resizing landmarks ArrayList", .{});
            @panic("OOM");
        };
        for (array.items, 0..) |*l, i| {
            l.* = landmarks_ptr[i];
        }
        break :blk array.toOwnedSlice(allocator) catch {
            std.log.err("Ran out of memory while taking ownership of the landmarks ArrayList", .{});
            @panic("OOM");
        };
    };
    defer allocator.free(landmarks);

    var aligned: Image(Rgba) = .init(out_rows, out_cols, out_ptr[0 .. out_rows * out_cols]);
    extractAlignedFace(Rgba, allocator, image, landmarks, padding, blurring, &aligned) catch {
        std.log.err("Ran out of memory while extracting the aligned face", .{});
        @panic("OOM");
    };
}

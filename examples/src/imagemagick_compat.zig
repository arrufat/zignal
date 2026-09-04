//! Verifies zignal's codecs against ImageMagick.
//!
//! For every fixture written by scripts/generate_imagemagick_fixtures.sh
//! (foo.{bmp,png,jpg,gif} with a foo.ref.png sibling), decodes the fixture
//! with zignal and PSNR-checks it against ImageMagick's own decode of the
//! same bytes. Also round-trips the synthetic sources through each zignal
//! encoder. Exits nonzero on any failure so it can run in CI.

const std = @import("std");
const zignal = @import("zignal");
const Image = zignal.Image;
const Rgba = zignal.Rgba(u8);

const default_dir = "fixtures/imagemagick";

// ImageMagick and zignal must agree bit-for-bit on lossless formats; JPEG
// decoders legitimately differ (IDCT/upsampling), and GIF/palette encodes
// quantize, so those get dB thresholds.
fn minPsnr(name: []const u8) f64 {
    // 4:2:0 JPEGs sit near 33 dB: zignal interpolates chroma only within an
    // MCU, while ImageMagick's libjpeg upsamples across block boundaries.
    if (std.mem.endsWith(u8, name, ".jpg")) return 32.0;
    // 16-bit PNG: the .ref.png is IM's own 16->8 conversion, which may round
    // differently than zignal's.
    if (std.mem.indexOf(u8, name, "_16") != null) return 45.0;
    return std.math.inf(f64);
}

fn checkPair(io: std.Io, gpa: std.mem.Allocator, dir: []const u8, name: []const u8, failures: *usize) !bool {
    const stem = name[0..std.mem.lastIndexOfScalar(u8, name, '.').?];
    const fixture_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name });
    defer gpa.free(fixture_path);
    const ref_path = try std.fmt.allocPrint(gpa, "{s}/{s}.ref.png", .{ dir, stem });
    defer gpa.free(ref_path);

    var reference: Image(Rgba) = Image(Rgba).load(io, gpa, ref_path) catch |err| switch (err) {
        // Not a script-generated fixture (e.g. leftover round-trip output).
        error.FileNotFound => return false,
        else => return err,
    };
    defer reference.deinit(gpa);
    var fixture: Image(Rgba) = Image(Rgba).load(io, gpa, fixture_path) catch |err| {
        std.debug.print("FAIL {s}: decode error {t}\n", .{ name, err });
        failures.* += 1;
        return true;
    };
    defer fixture.deinit(gpa);

    const db = try fixture.psnr(reference);
    const threshold = minPsnr(name);
    const ok = db >= threshold;
    if (!ok) failures.* += 1;
    std.debug.print("{s} {s}: PSNR {d:.2} dB (min {d:.0})\n", .{ if (ok) "ok  " else "FAIL", name, db, threshold });
    return true;
}

fn checkAnimated(io: std.Io, gpa: std.mem.Allocator, dir: []const u8, failures: *usize) !void {
    const gif_path = try std.fmt.allocPrint(gpa, "{s}/gif_animated.gif", .{dir});
    defer gpa.free(gif_path);
    var anim = zignal.gif.loadAnimated(Rgba, io, gpa, gif_path, .{}) catch |err| {
        std.debug.print("FAIL gif_animated.gif: decode error {t}\n", .{err});
        failures.* += 1;
        return;
    };
    defer anim.deinit(gpa);

    for (0..anim.frameCount()) |i| {
        const ref_path = try std.fmt.allocPrint(gpa, "{s}/gif_animated.ref-{d:0>2}.png", .{ dir, i });
        defer gpa.free(ref_path);
        var reference: Image(Rgba) = try .load(io, gpa, ref_path);
        defer reference.deinit(gpa);

        const db = try anim.frame(i).psnr(reference);
        const ok = db >= 35.0;
        if (!ok) failures.* += 1;
        std.debug.print("{s} gif_animated.gif frame {d}: PSNR {d:.2} dB (min 35)\n", .{ if (ok) "ok  " else "FAIL", i, db });
    }
}

fn roundtrip(
    comptime codec: anytype,
    comptime label: []const u8,
    gpa: std.mem.Allocator,
    src: Image(Rgba),
    threshold: f64,
    failures: *usize,
) !void {
    const bytes = try codec.encode(Rgba, gpa, src, .default);
    defer gpa.free(bytes);
    var back = try codec.loadFromBytes(Rgba, io, gpa, bytes, .{});
    defer back.deinit(gpa);

    const db = try back.psnr(src);
    const ok = db >= threshold;
    if (!ok) failures.* += 1;
    std.debug.print("{s} roundtrip {s}: PSNR {d:.2} dB (min {d:.0})\n", .{ if (ok) "ok  " else "FAIL", label, db, threshold });
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip();
    const dir_path = args.next() orelse default_dir;

    var failures: usize = 0;
    var checked: usize = 0;

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }

    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        const is_fixture = (std.mem.endsWith(u8, name, ".bmp") or std.mem.endsWith(u8, name, ".jpg") or
            std.mem.endsWith(u8, name, ".gif") or std.mem.endsWith(u8, name, ".png")) and
            std.mem.indexOf(u8, name, ".ref") == null and
            !std.mem.startsWith(u8, name, "src_") and
            !std.mem.eql(u8, name, "gif_animated.gif");
        if (is_fixture) try names.append(gpa, try gpa.dupe(u8, name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    for (names.items) |name| {
        if (try checkPair(io, gpa, dir_path, name, &failures)) checked += 1;
    }
    try checkAnimated(io, gpa, dir_path, &failures);
    checked += 1;

    // Encoder round-trips: alpha-capable formats use the RGBA source; JPEG and
    // GIF cannot represent its transparent disc, so they use the opaque source.
    const src_rgba_path = try std.fmt.allocPrint(gpa, "{s}/src_rgba.png", .{dir_path});
    defer gpa.free(src_rgba_path);
    var src_rgba: Image(Rgba) = try .load(io, gpa, src_rgba_path);
    defer src_rgba.deinit(gpa);
    const src_rgb_path = try std.fmt.allocPrint(gpa, "{s}/src_rgb.png", .{dir_path});
    defer gpa.free(src_rgb_path);
    var src_rgb: Image(Rgba) = try .load(io, gpa, src_rgb_path);
    defer src_rgb.deinit(gpa);

    try roundtrip(zignal.png, "png", gpa, src_rgba, std.math.inf(f64), &failures);
    try roundtrip(zignal.bmp, "bmp", gpa, src_rgba, std.math.inf(f64), &failures);
    try roundtrip(zignal.jpeg, "jpeg", gpa, src_rgb, 30.0, &failures);
    try roundtrip(zignal.gif, "gif", gpa, src_rgb, 25.0, &failures);
    checked += 4;

    std.debug.print("\n{d} checks, {d} failures\n", .{ checked, failures });
    return if (failures == 0) 0 else 1;
}

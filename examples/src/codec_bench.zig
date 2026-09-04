//! Codec throughput: decodes each file given on the command line from memory and re-encodes
//! the result as JPEG (quality 90, 4:2:0) and PNG (default options); best of several runs.
//! `zig build run-codec-bench --release -- a.png b.jpg`
const std = @import("std");
const zignal = @import("zignal");
const Image = zignal.Image;
const Rgb = zignal.Rgb(u8);

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).toNanoseconds();
}

fn ms(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip();

    std.debug.print("{s:<24} {s:>10} {s:>10} {s:>13} {s:>10} {s:>12} {s:>10}\n", .{ "zignal", "size", "decode ms", "jpeg enc ms", "jpeg B", "png enc ms", "png B" });
    while (args.next()) |path| {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 30));
        defer gpa.free(data);
        var probe = try Image(Rgb).loadFromBytes(io, gpa, data);
        defer probe.deinit(gpa);
        const iters: usize = if (probe.rows * probe.cols > 4_000_000) 3 else 7;

        var decode: i96 = std.math.maxInt(i96);
        for (0..iters) |_| {
            const t = nowNs(io);
            var img = try Image(Rgb).loadFromBytes(io, gpa, data);
            decode = @min(decode, nowNs(io) - t);
            img.deinit(gpa);
        }
        var jpeg_ns: i96 = std.math.maxInt(i96);
        var jpeg_len: usize = 0;
        for (0..iters) |_| {
            const t = nowNs(io);
            const bytes = try zignal.jpeg.encode(Rgb, io, gpa, probe, .default);
            jpeg_ns = @min(jpeg_ns, nowNs(io) - t);
            jpeg_len = bytes.len;
            gpa.free(bytes);
        }
        var png_ns: i96 = std.math.maxInt(i96);
        var png_len: usize = 0;
        for (0..iters) |_| {
            const t = nowNs(io);
            const bytes = try zignal.png.encode(Rgb, io, gpa, probe, .default);
            png_ns = @min(png_ns, nowNs(io) - t);
            png_len = bytes.len;
            gpa.free(bytes);
        }
        const base = std.fs.path.basename(path);
        std.debug.print("{s:<24} {d}x{d:<5} {d:>10.1} {d:>13.1} {d:>10} {d:>12.1} {d:>10}\n", .{ base, probe.cols, probe.rows, ms(decode), ms(jpeg_ns), jpeg_len, ms(png_ns), png_len });
    }
}

const std = @import("std");
const builtin = @import("builtin");
const zignal = @import("zignal");
const perlin = zignal.perlin;
const PerlinOptions = zignal.PerlinOptions;
const Rgba = zignal.Rgba(u8);
const Image = zignal.Image;

pub const std_options: std.Options = .{
    .logFn = if (builtin.cpu.arch.isWasm()) @import("js.zig").logFn else std.log.defaultLog,
    .log_level = .info,
};

var opts: PerlinOptions(f32) = .{
    .amplitude = 1,
    .frequency = 1,
    .octaves = 1,
    .persistence = 0.5,
    .lacunarity = 2,
};

pub export fn set_amplitude(val: f32) void {
    std.log.debug("setting amplitude to {d}", .{val});
    opts.amplitude = val;
}
pub export fn set_frequency(val: f32) void {
    std.log.debug("setting frequency to {d}", .{val});
    opts.frequency = val;
}

pub export fn set_octaves(val: usize) void {
    std.log.debug("setting octaves to {d}", .{val});
    opts.octaves = val;
}

pub export fn set_persistence(val: f32) void {
    std.log.debug("setting persistence to {d}", .{val});
    opts.persistence = val;
}

pub export fn set_lacunarity(val: f32) void {
    std.log.debug("setting lacunarity to {d}", .{val});
    opts.lacunarity = val;
}

pub export fn generate(rgba_ptr: [*]Rgba, rows: u32, cols: u32) void {
    const size = @as(usize, rows) * @as(usize, cols);
    const image: Image(Rgba) = .initFromSlice(rows, cols, rgba_ptr[0..size]);
    for (0..image.rows) |r| {
        const y: f32 = @as(f32, @floatFromInt(r)) / @as(f32, @floatFromInt(image.rows));
        for (0..image.cols) |c| {
            const x: f32 = @as(f32, @floatFromInt(c)) / @as(f32, @floatFromInt(image.cols));
            const val: u8 = @intFromFloat(
                @max(0, @min(255, @round(
                    255 * (opts.amplitude / 2 * (perlin(f32, x, y, 0, opts) + opts.amplitude)),
                ))),
            );
            image.at(r, c).* = (zignal.Gray(u8){ .y = val }).to(.rgb).withAlpha(255);
        }
    }
}

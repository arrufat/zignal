const std = @import("std");
const builtin = @import("builtin");
const perlin = @import("zignal").perlin;
const Rgba = @import("zignal").Rgba;
const Image = @import("zignal").Image;

pub const std_options: std.Options = .{
    .logFn = if (builtin.cpu.arch.isWasm()) @import("js.zig").logFn else std.log.defaultLog,
    .log_level = .info,
};

var opts = perlin.Options(f32){
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

pub export fn generate(rgba_ptr: [*]Rgba, rows: usize, cols: usize) void {
    const size = rows * cols;
    const image = Image(Rgba).init(rows, cols, rgba_ptr[0..size]);
    for (0..image.rows) |r| {
        const y: f32 = @as(f32, @floatFromInt(r)) / @as(f32, @floatFromInt(image.rows));
        for (0..image.cols) |c| {
            const pos = r * image.cols + c;
            const x: f32 = @as(f32, @floatFromInt(c)) / @as(f32, @floatFromInt(image.cols));
            const val: u8 = @intFromFloat(
                @max(0, @min(255, @round(
                    255 * (opts.amplitude / 2 * (perlin.generate(f32, x, y, 0, opts) + opts.amplitude)),
                ))),
            );
            image.data[pos] = Rgba.fromGray(val, 255);
        }
    }
}

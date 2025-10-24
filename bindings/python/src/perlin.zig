const std = @import("std");

const zignal = @import("zignal");

const py_utils = @import("py_utils.zig");
const c = py_utils.c;
const stub_metadata = @import("stub_metadata.zig");

const max_octaves: c_long = 32;
const max_lacunarity: f64 = 16.0;

const perlin_doc = std.fmt.comptimePrint(
    \\Sample 3D Perlin noise using Zignal's implementation.
    \\
    \\This computes classic Perlin noise with configurable amplitude, frequency,
    \\octave count, persistence, and lacunarity. All parameters are applied
    \\in a streaming fashion, making it convenient for procedural textures and
    \\augmentation workflows.
    \\
    \\## Parameters
    \\- `x` (float): X coordinate in noise space.
    \\- `y` (float): Y coordinate in noise space.
    \\- `z` (float, optional): Z coordinate (default 0.0). Use for animated noise.
    \\- `amplitude` (float, default 1.0): Output scaling factor (> 0).
    \\- `frequency` (float, default 1.0): Base spatial frequency (> 0).
    \\- `octaves` (int, default 1): Number of summed octaves (1-{d}).
    \\- `persistence` (float, default 0.5): Amplitude decay per octave (0-1).
    \\- `lacunarity` (float, default 2.0): Frequency growth per octave (1.0-{s}).
    \\
    \\## Returns
    \\float: Perlin noise sample at `(x, y, z)` with the given parameters.
,
    .{ max_octaves, std.fmt.comptimePrint("{d}", .{max_lacunarity}) },
);

fn perlin_function(_: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct {
        x: f64,
        y: f64,
        z: f64 = 0,
        amplitude: f64 = 1,
        frequency: f64 = 1,
        octaves: c_long = 1,
        persistence: f64 = 0.5,
        lacunarity: f64 = 2,
    };

    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const options = zignal.PerlinOptions(f64){
        .amplitude = py_utils.validatePositive(f64, params.amplitude, "amplitude") catch return null,
        .frequency = py_utils.validatePositive(f64, params.frequency, "frequency") catch return null,
        .octaves = @intCast(py_utils.validateRange(c_long, params.octaves, 1, max_octaves, "octaves") catch return null),
        .persistence = py_utils.validateRange(f64, params.persistence, 0.0, 1.0, "persistence") catch return null,
        .lacunarity = py_utils.validateRange(f64, params.lacunarity, 1.0, max_lacunarity, "lacunarity") catch return null,
    };

    const value = zignal.perlin(f64, params.x, params.y, params.z, options);
    return c.PyFloat_FromDouble(value);
}

pub const perlin_functions_metadata = [_]stub_metadata.FunctionWithMetadata{
    .{
        .name = "perlin",
        .meth = @ptrCast(&perlin_function),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = perlin_doc,
        .params = "x: float, y: float, z: float = 0.0, amplitude: float = 1.0, frequency: float = 1.0, octaves: int = 1, persistence: float = 0.5, lacunarity: float = 2.0",
        .returns = "float",
    },
};

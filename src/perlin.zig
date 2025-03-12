const std = @import("std");
const assert = std.debug.assert;
const lerp = std.math.lerp;
const expectEqual = std.testing.expectEqual;

/// Controls how Perlin noise is generated.
pub fn Options(T: type) type {
    return struct {
        /// The amplitude of the generated noise
        amplitude: T = 1,
        /// The scaling in each dimension before noise is called.
        frequency: T = 1,
        /// How many times the function will be called.
        octaves: usize = 1,
        /// Gain [0, 1], controls how quickly the octaves die out.  A value of 0.5 is a
        /// conventional choice.
        persistence: T = 0.5,
        /// Determines how much finer a scale each subsequent octave should use.
        /// It should be greater than one, and 2.0 is a good choice.
        lacunarity: T = 2,

        /// Initializes PerlinOptions while checking the ranges are correct.
        pub fn init(amplitude: T, frequency: T, octaves: usize, persistence: T, lacunarity: T) Options(T) {
            {
                @setRuntimeSafety(true);
                assert(amplitude > 0);
                assert(frequency > 0);
                assert(octaves > 0);
                assert(persistence >= 0 and persistence <= 1);
                assert(lacunarity >= 1);
            }
            return .{
                .amplitude = amplitude,
                .frequency = frequency,
                .octaves = octaves,
                .persistence = persistence,
                .lacunarity = lacunarity,
            };
        }
    };
}

/// Generates perlin noise using the specified options.
pub fn generate(T: type, x: T, y: T, z: T, opts: Options(T)) T {
    var total_noise: T = 0;
    var max_amplitude: T = 0.0;
    var cur_amplitude: T = 1;
    var cur_frequency: T = opts.frequency;
    for (0..opts.octaves) |_| {
        total_noise += noise(T, x * cur_frequency, y * cur_frequency, z * cur_frequency) * cur_amplitude;
        cur_amplitude *= opts.persistence;
        cur_frequency *= opts.lacunarity;
        max_amplitude += cur_amplitude;
    }
    return total_noise / max_amplitude * opts.amplitude;
}

// The functions below are ported from: https://mrl.cs.nyu.edu/~perlin/noise/

fn noise(T: type, x: T, y: T, z: T) T {
    assert(@typeInfo(T) == .float);
    // Find unit cube that contains the point.
    const x_i: u8 = @intCast(@as(isize, @intFromFloat(@floor(x))) & 255);
    const y_i: u8 = @intCast(@as(isize, @intFromFloat(@floor(y))) & 255);
    const z_i: u8 = @intCast(@as(isize, @intFromFloat(@floor(z))) & 255);

    // Find relative x, y, z of the point in the cube.
    const x_r = x - @floor(x);
    const y_r = y - @floor(y);
    const z_r = z - @floor(z);

    // Compute the fade curves for each x, y.
    const u = fade(T, x_r);
    const v = fade(T, y_r);
    const w = fade(T, z_r);

    // Hash the coordinates of the corners.
    const a = permutation[x_i] +% y_i;
    const aa = permutation[a] +% z_i;
    const ab = permutation[a +% 1] +% z_i;
    const b = permutation[x_i +% 1] +% y_i;
    const ba = permutation[b] +% z_i;
    const bb = permutation[b +% 1] +% z_i;

    // Add blended results from all 8 corners.
    return lerp(lerp(lerp(
        grad(T, permutation[aa], x_r, y_r, z_r),
        grad(T, permutation[ba], x_r - 1, y_r, z_r),
        u,
    ), lerp(
        grad(T, permutation[ab], x_r, y_r - 1, z_r),
        grad(T, permutation[bb], x_r - 1, y_r - 1, z_r),
        u,
    ), v), lerp(lerp(
        grad(T, permutation[aa +% 1], x_r, y_r, z_r - 1),
        grad(T, permutation[ba +% 1], x_r - 1, y_r, z_r - 1),
        u,
    ), lerp(
        grad(T, permutation[ab +% 1], x_r, y_r - 1, z_r - 1),
        grad(T, permutation[bb +% 1], x_r - 1, y_r - 1, z_r - 1),
        u,
    ), v), w);
}

test "noise" {
    try expectEqual(noise(f64, 0, 0, 0), 0);
    try expectEqual(noise(f64, 1, 1, 1), 0);
    try expectEqual(noise(f64, -1, -1, -1), 0);
    try expectEqual(noise(f64, 0.5, 0.5, 0.5), -0.25);
    try expectEqual(noise(f64, 0.1, 0.1, 0.1), 0.1861607143544832);
    try expectEqual(noise(f64, 3.14, 42, 0), 0.13691995878400012);
    try expectEqual(noise(f64, -4.20, 10, 0), -0.14208000000000043);
}

fn fade(T: type, t: T) T {
    return t * t * t * (t * (t * 6 - 15) + 10);
}

test "fade" {
    try expectEqual(fade(f64, 0.75), 0.896484375);
}

// Convert the low 4 bits of the hash code into 12 gradient directions.
fn grad(T: type, hash: u8, x: T, y: T, z: T) T {
    return switch (@as(u4, @truncate(hash))) {
        0, 12 => x + y,
        1, 14 => y - x,
        2 => x - y,
        3 => -x - y,
        4 => x + z,
        5 => z - x,
        6 => x - z,
        7 => -x - z,
        8 => y + z,
        9, 13 => z - y,
        10 => y - z,
        11, 15 => -y - z,
    };
}

test "grad" {
    try expectEqual(grad(f64, 69, 3.14, 42, 0), -3.14);
}

// Just to make sure the switch implementation matches the original one, directly ported from:
// https://mrl.cs.nyu.edu/~perlin/noise/
test "grad perlin" {
    const gp = struct {
        fn lambda(T: type, hash: u8, x: T, y: T, z: T) T {
            const h: u4 = @truncate(hash);
            const u: T = if (h < 8) x else y;
            const v: T = if (h < 4) y else if (h == 12 or h == 14) x else z;
            return (if ((h & 1) == 0) u else -u) + (if ((h & 2) == 0) v else -v);
        }
    }.lambda;
    var prng: std.Random.DefaultPrng = .init(0);
    const random = prng.random();
    for (0..100) |_| {
        const hash = random.int(u8);
        const x = random.float(f64);
        const y = random.float(f64);
        const z = random.float(f64);
        try expectEqual(grad(f64, hash, x, y, z), gp(f64, hash, x, y, z));
    }
}

const permutation = [256]u8{
    151, 160, 137, 91,  90,  15,  131, 13,  201, 95,  96,  53,  194, 233, 7,   225,
    140, 36,  103, 30,  69,  142, 8,   99,  37,  240, 21,  10,  23,  190, 6,   148,
    247, 120, 234, 75,  0,   26,  197, 62,  94,  252, 219, 203, 117, 35,  11,  32,
    57,  177, 33,  88,  237, 149, 56,  87,  174, 20,  125, 136, 171, 168, 68,  175,
    74,  165, 71,  134, 139, 48,  27,  166, 77,  146, 158, 231, 83,  111, 229, 122,
    60,  211, 133, 230, 220, 105, 92,  41,  55,  46,  245, 40,  244, 102, 143, 54,
    65,  25,  63,  161, 1,   216, 80,  73,  209, 76,  132, 187, 208, 89,  18,  169,
    200, 196, 135, 130, 116, 188, 159, 86,  164, 100, 109, 198, 173, 186, 3,   64,
    52,  217, 226, 250, 124, 123, 5,   202, 38,  147, 118, 126, 255, 82,  85,  212,
    207, 206, 59,  227, 47,  16,  58,  17,  182, 189, 28,  42,  223, 183, 170, 213,
    119, 248, 152, 2,   44,  154, 163, 70,  221, 153, 101, 155, 167, 43,  172, 9,
    129, 22,  39,  253, 19,  98,  108, 110, 79,  113, 224, 232, 178, 185, 112, 104,
    218, 246, 97,  228, 251, 34,  242, 193, 238, 210, 144, 12,  191, 179, 162, 241,
    81,  51,  145, 235, 249, 14,  239, 107, 49,  192, 214, 31,  181, 199, 106, 157,
    184, 84,  204, 176, 115, 121, 50,  45,  127, 4,   150, 254, 138, 236, 205, 93,
    222, 114, 67,  29,  24,  72,  243, 141, 128, 195, 78,  66,  215, 61,  156, 180,
};

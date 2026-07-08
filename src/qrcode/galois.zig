//! GF(256) arithmetic over the QR code polynomial x^8 + x^4 + x^3 + x^2 + 1 (0x11d).

const std = @import("std");
const assert = std.debug.assert;

/// Number of non-zero field elements.
pub const order = 255;

const tables = blk: {
    @setEvalBranchQuota(10_000);
    // exp is doubled so mul can index exp[log a + log b] without a modulo.
    var exp: [2 * order]u8 = undefined;
    var log: [256]u8 = undefined;
    var x: u16 = 1;
    for (0..order) |i| {
        exp[i] = x;
        log[x] = i;
        x <<= 1;
        if (x >= 256) x ^= 0x11d;
    }
    for (order..2 * order) |i| exp[i] = exp[i - order];
    log[0] = 0; // log(0) is undefined; callers must never use it.
    break :blk .{ .exp = exp, .log = log };
};

/// Returns alpha^i, where alpha = 2 is the field generator.
pub fn expAlpha(i: usize) u8 {
    return tables.exp[i % order];
}

pub fn mul(a: u8, b: u8) u8 {
    if (a == 0 or b == 0) return 0;
    return tables.exp[@as(usize, tables.log[a]) + tables.log[b]];
}

pub fn div(a: u8, b: u8) u8 {
    assert(b != 0);
    if (a == 0) return 0;
    return tables.exp[@as(usize, tables.log[a]) + order - tables.log[b]];
}

pub fn inv(a: u8) u8 {
    assert(a != 0);
    return tables.exp[order - @as(usize, tables.log[a])];
}

/// Evaluates a polynomial with coefficients in lowest-degree-first order at x.
pub fn polyEval(poly: []const u8, x: u8) u8 {
    var y: u8 = 0;
    var i = poly.len;
    while (i > 0) {
        i -= 1;
        y = mul(y, x) ^ poly[i];
    }
    return y;
}

test "exp/log are inverses" {
    for (1..256) |a| {
        const v: u8 = @intCast(a);
        try std.testing.expectEqual(v, tables.exp[tables.log[v]]);
    }
    for (0..order) |i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), tables.log[tables.exp[i]]);
    }
}

test "multiplicative inverse" {
    for (1..256) |a| {
        const v: u8 = @intCast(a);
        try std.testing.expectEqual(@as(u8, 1), mul(v, inv(v)));
        try std.testing.expectEqual(@as(u8, 1), div(v, v));
    }
}

test "known products" {
    // From the field's defining relation: alpha^8 = 0x1d.
    try std.testing.expectEqual(@as(u8, 0x1d), expAlpha(8));
    try std.testing.expectEqual(@as(u8, 0), mul(0, 123));
    try std.testing.expectEqual(@as(u8, 123), mul(1, 123));
}

test "polyEval" {
    // p(x) = 3x^2 + 2x + 1 at x = 1 is 3 ^ 2 ^ 1 = 0.
    const p = [_]u8{ 1, 2, 3 };
    try std.testing.expectEqual(@as(u8, 0), polyEval(&p, 1));
    try std.testing.expectEqual(@as(u8, 1), polyEval(&p, 0));
}

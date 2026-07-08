//! Reed-Solomon error correction over GF(256) as used by QR codes:
//! generator roots alpha^0..alpha^(ecc_len-1), codeword = data ++ ecc.

const std = @import("std");
const assert = std.debug.assert;

const gf = @import("galois.zig");

/// Maximum number of error correction codewords per block in a QR code.
pub const max_ecc_len = 30;

/// Generator polynomials for every degree up to max_ecc_len, highest-degree
/// coefficient first (monic, so [degree][0] == 1). Each row multiplies the
/// previous one by (x + alpha^i).
const generators: [max_ecc_len + 1][max_ecc_len + 1]u8 = blk: {
    @setEvalBranchQuota(100_000);
    var table: [max_ecc_len + 1][max_ecc_len + 1]u8 = undefined;
    table[0] = @splat(0);
    table[0][0] = 1;
    for (1..max_ecc_len + 1) |degree| {
        const a = gf.expAlpha(degree - 1);
        const prev = table[degree - 1];
        var row: [max_ecc_len + 1]u8 = @splat(0);
        row[0] = 1;
        for (1..degree) |k| row[k] = prev[k] ^ gf.mul(a, prev[k - 1]);
        row[degree] = gf.mul(a, prev[degree - 1]);
        table[degree] = row;
    }
    break :blk table;
};

fn generator(degree: usize) []const u8 {
    assert(degree <= max_ecc_len);
    return generators[degree][0 .. degree + 1];
}

/// Computes the error correction codewords for data; ecc.len selects the degree.
pub fn encode(data: []const u8, ecc: []u8) void {
    const gen = generator(ecc.len);
    @memset(ecc, 0);
    for (data) |d| {
        const factor = d ^ ecc[0];
        std.mem.copyForwards(u8, ecc[0 .. ecc.len - 1], ecc[1..]);
        ecc[ecc.len - 1] = 0;
        if (factor != 0) {
            for (ecc, gen[1..]) |*e, g| e.* ^= gf.mul(g, factor);
        }
    }
}

fn syndromes(codeword: []const u8, ecc_len: usize, out: *[max_ecc_len]u8) bool {
    var has_error = false;
    for (0..ecc_len) |i| {
        // The codeword is highest-degree-first, so evaluate directly with Horner.
        var s: u8 = 0;
        const x = gf.expAlpha(i);
        for (codeword) |c| s = gf.mul(s, x) ^ c;
        out[i] = s;
        if (s != 0) has_error = true;
    }
    return has_error;
}

/// Corrects up to ecc_len/2 symbol errors in place; the last ecc_len bytes of
/// codeword are the error correction codewords. Returns the number of
/// corrected symbols, or error.TooManyErrors if the block is uncorrectable.
pub fn decode(codeword: []u8, ecc_len: usize) !usize {
    assert(ecc_len >= 2 and ecc_len <= max_ecc_len and codeword.len > ecc_len);
    const n = codeword.len;

    var synd: [max_ecc_len]u8 = undefined;
    if (!syndromes(codeword, ecc_len, &synd)) return 0;

    // Berlekamp-Massey: find the error locator polynomial lambda
    // (lowest-degree-first, lambda[0] == 1).
    var lambda: [max_ecc_len + 1]u8 = @splat(0);
    var prev: [max_ecc_len + 1]u8 = @splat(0);
    lambda[0] = 1;
    prev[0] = 1;
    var num_errors: usize = 0; // current degree of lambda
    var shift: usize = 1; // iterations since prev was updated
    var prev_discrepancy: u8 = 1;
    for (0..ecc_len) |iter| {
        var discrepancy = synd[iter];
        for (1..num_errors + 1) |i| discrepancy ^= gf.mul(lambda[i], synd[iter - i]);
        if (discrepancy == 0) {
            shift += 1;
        } else if (2 * num_errors <= iter) {
            const tmp = lambda;
            const coef = gf.div(discrepancy, prev_discrepancy);
            for (shift..max_ecc_len + 1) |i| lambda[i] ^= gf.mul(coef, prev[i - shift]);
            prev = tmp;
            prev_discrepancy = discrepancy;
            num_errors = iter + 1 - num_errors;
            shift = 1;
        } else {
            const coef = gf.div(discrepancy, prev_discrepancy);
            for (shift..max_ecc_len + 1) |i| lambda[i] ^= gf.mul(coef, prev[i - shift]);
            shift += 1;
        }
    }
    if (num_errors > ecc_len / 2) return error.TooManyErrors;

    // Chien search: an error at byte index k corresponds to the locator
    // X = alpha^(n-1-k); k is an error position iff lambda(X^-1) == 0.
    var positions: [max_ecc_len / 2]usize = undefined;
    var count: usize = 0;
    for (0..n) |k| {
        const power = n - 1 - k;
        const x_inv = gf.expAlpha(gf.order - power % gf.order);
        if (gf.polyEval(lambda[0 .. num_errors + 1], x_inv) == 0) {
            if (count == num_errors) return error.TooManyErrors;
            positions[count] = k;
            count += 1;
        }
    }
    if (count != num_errors) return error.TooManyErrors;

    // Forney: omega = synd * lambda mod x^ecc_len, then
    // e_k = X * omega(X^-1) / lambda'(X^-1).
    var omega: [max_ecc_len]u8 = @splat(0);
    for (0..ecc_len) |j| {
        for (0..@min(j + 1, num_errors + 1)) |i| {
            omega[j] ^= gf.mul(lambda[i], synd[j - i]);
        }
    }
    for (positions[0..count]) |k| {
        const power = (n - 1 - k) % gf.order;
        const x = gf.expAlpha(power);
        const x_inv = gf.expAlpha(gf.order - power);
        // lambda'(x) in characteristic 2 keeps only the odd-degree terms.
        var denom: u8 = 0;
        var i: usize = 1;
        while (i <= num_errors) : (i += 2) {
            var term = lambda[i];
            for (0..i - 1) |_| term = gf.mul(term, x_inv);
            denom ^= term;
        }
        if (denom == 0) return error.TooManyErrors;
        codeword[k] ^= gf.mul(x, gf.div(gf.polyEval(omega[0..ecc_len], x_inv), denom));
    }

    // A failed correction must not go unnoticed: recheck the syndromes.
    if (syndromes(codeword, ecc_len, &synd)) return error.TooManyErrors;
    return count;
}

test "generator polynomial degree 7" {
    // ISO/IEC 18004: g(x) = x^7 + a^87 x^6 + a^229 x^5 + a^146 x^4 + a^149 x^3
    //                + a^238 x^2 + a^102 x + a^21.
    const gen = generator(7);
    const alpha_exponents = [_]u8{ 0, 87, 229, 146, 149, 238, 102, 21 };
    for (gen, alpha_exponents) |coef, e| {
        try std.testing.expectEqual(gf.expAlpha(e), coef);
    }
}

test "ISO 18004 Annex I error correction codewords" {
    // "01234567", version 1-M: 16 data codewords, 10 ecc codewords.
    const data = [_]u8{ 0x10, 0x20, 0x0c, 0x56, 0x61, 0x80, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11 };
    const expected = [_]u8{ 0xa5, 0x24, 0xd4, 0xc1, 0xed, 0x36, 0xc7, 0x87, 0x2c, 0x55 };
    var ecc: [10]u8 = undefined;
    encode(&data, &ecc);
    try std.testing.expectEqualSlices(u8, &expected, &ecc);
}

test "decode corrects injected errors" {
    var prng: std.Random.DefaultPrng = .init(0x9e3779b9);
    const random = prng.random();
    for (0..2000) |_| {
        const ecc_len = random.intRangeAtMost(usize, 7, max_ecc_len);
        const data_len = random.intRangeAtMost(usize, 1, 255 - ecc_len);
        var codeword: [255]u8 = undefined;
        random.bytes(codeword[0..data_len]);
        encode(codeword[0..data_len], codeword[data_len .. data_len + ecc_len]);
        const original = codeword;

        const n = data_len + ecc_len;
        const num_errors = random.intRangeAtMost(usize, 0, ecc_len / 2);
        var corrupted: usize = 0;
        while (corrupted < num_errors) {
            const pos = random.intRangeLessThan(usize, 0, n);
            const flip = random.int(u8);
            if (flip != 0 and codeword[pos] == original[pos]) {
                codeword[pos] ^= flip;
                corrupted += 1;
            }
        }

        const corrected = try decode(codeword[0..n], ecc_len);
        try std.testing.expectEqual(corrupted, corrected);
        try std.testing.expectEqualSlices(u8, original[0..n], codeword[0..n]);
    }
}

test "decode rejects or detects excess errors" {
    var prng: std.Random.DefaultPrng = .init(0x517cc1b7);
    const random = prng.random();
    for (0..500) |_| {
        const ecc_len = random.intRangeAtMost(usize, 7, max_ecc_len);
        const data_len = random.intRangeAtMost(usize, 8, 255 - ecc_len);
        var codeword: [255]u8 = undefined;
        random.bytes(codeword[0..data_len]);
        encode(codeword[0..data_len], codeword[data_len .. data_len + ecc_len]);
        const original = codeword;

        // One error beyond the correction capacity: must not "correct" back to
        // a codeword that differs from the original without erroring.
        const n = data_len + ecc_len;
        var corrupted: usize = 0;
        while (corrupted < ecc_len / 2 + 1) {
            const pos = random.intRangeLessThan(usize, 0, n);
            const flip = random.int(u8);
            if (flip != 0 and codeword[pos] == original[pos]) {
                codeword[pos] ^= flip;
                corrupted += 1;
            }
        }

        if (decode(codeword[0..n], ecc_len)) |_| {
            // Miscorrection to a different valid codeword is information-
            // theoretically possible; it must still be a valid codeword.
            var synd: [max_ecc_len]u8 = undefined;
            try std.testing.expect(!syndromes(codeword[0..n], ecc_len, &synd));
        } else |err| {
            try std.testing.expectEqual(error.TooManyErrors, err);
        }
    }
}

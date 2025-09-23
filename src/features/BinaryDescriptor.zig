//! A binary descriptor is a compact representation of an image patch
//! using binary strings. Each bit encodes a simple intensity comparison.
//! 256 bits (32 bytes) provides a good balance between discriminability and size.

const std = @import("std");
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;

/// 256 bits stored as 32 bytes
bits: [32]u8,

const BinaryDescriptor = @This();

/// Initialize with all zeros
pub fn init() BinaryDescriptor {
    return .{ .bits = @splat(0) };
}

/// Compute Hamming distance to another descriptor.
/// This is the number of bits that differ between descriptors.
pub fn hammingDistance(self: BinaryDescriptor, other: BinaryDescriptor) u32 {
    const vec_self: @Vector(32, u8) = self.bits;
    const vec_other: @Vector(32, u8) = other.bits;
    const popcount = @popCount(vec_self ^ vec_other);

    // Need to sum as u32 to avoid overflow (max sum is 256)
    var sum: u32 = 0;
    inline for (0..32) |i| sum += popcount[i];
    return sum;
}

/// Set a specific bit in the descriptor
pub fn setBit(self: *BinaryDescriptor, index: usize) void {
    assert(index < 256);
    const byte_idx = index / 8;
    const bit_idx = @as(u3, @intCast(index % 8));
    self.bits[byte_idx] |= @as(u8, 1) << bit_idx;
}

/// Clear a specific bit in the descriptor
pub fn clearBit(self: *BinaryDescriptor, index: usize) void {
    assert(index < 256);
    const byte_idx = index / 8;
    const bit_idx = @as(u3, @intCast(index % 8));
    self.bits[byte_idx] &= ~(@as(u8, 1) << bit_idx);
}

/// Get a specific bit from the descriptor
pub fn getBit(self: BinaryDescriptor, index: usize) bool {
    assert(index < 256);
    const byte_idx = index / 8;
    const bit_idx = @as(u3, @intCast(index % 8));
    return (self.bits[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
}

/// Check if two descriptors are identical
pub fn equals(self: BinaryDescriptor, other: BinaryDescriptor) bool {
    return std.mem.eql(u8, &self.bits, &other.bits);
}

/// Count the number of set bits (1s) in the descriptor
pub fn popCount(self: BinaryDescriptor) u32 {
    const vec: @Vector(32, u8) = self.bits;
    const popcount = @popCount(vec);

    // Sum as u32 to avoid overflow (max sum is 256)
    var sum: u32 = 0;
    inline for (0..32) |i| sum += popcount[i];
    return sum;
}

/// Create a random descriptor (useful for testing)
pub fn random(rng: std.Random) BinaryDescriptor {
    var desc = BinaryDescriptor.init();
    for (&desc.bits) |*byte| {
        byte.* = rng.int(u8);
    }
    return desc;
}

/// Compute normalized Hamming distance (0.0 to 1.0)
pub fn normalizedDistance(self: BinaryDescriptor, other: BinaryDescriptor) f32 {
    const dist = self.hammingDistance(other);
    return @as(f32, @floatFromInt(dist)) / 256.0;
}

// Tests
test "BinaryDescriptor initialization" {
    const desc = BinaryDescriptor.init();

    // Should be all zeros
    for (desc.bits) |byte| {
        try expectEqual(@as(u8, 0), byte);
    }

    try expectEqual(@as(u32, 0), desc.popCount());
}

test "BinaryDescriptor bit operations" {
    var desc = BinaryDescriptor.init();

    // Set some bits
    desc.setBit(0);
    desc.setBit(7);
    desc.setBit(8);
    desc.setBit(255);

    try expectEqual(true, desc.getBit(0));
    try expectEqual(true, desc.getBit(7));
    try expectEqual(true, desc.getBit(8));
    try expectEqual(true, desc.getBit(255));
    try expectEqual(false, desc.getBit(1));

    // Clear a bit
    desc.clearBit(7);
    try expectEqual(false, desc.getBit(7));

    // Check population count
    try expectEqual(@as(u32, 3), desc.popCount());
}

test "BinaryDescriptor Hamming distance" {
    var desc1 = BinaryDescriptor.init();
    var desc2 = BinaryDescriptor.init();

    // Same descriptors should have distance 0
    try expectEqual(@as(u32, 0), desc1.hammingDistance(desc2));

    // Set different bits
    desc1.setBit(0);
    desc1.setBit(10);
    desc1.setBit(100);

    desc2.setBit(0); // Same
    desc2.setBit(11); // Different
    desc2.setBit(101); // Different

    // Should have distance of 4 (2 bits only in desc1, 2 only in desc2)
    try expectEqual(@as(u32, 4), desc1.hammingDistance(desc2));
}

test "BinaryDescriptor normalized distance" {
    var desc1 = BinaryDescriptor.init();
    var desc2 = BinaryDescriptor.init();

    // Same descriptors
    try expectEqual(@as(f32, 0.0), desc1.normalizedDistance(desc2));

    // Set half the bits differently (128 bits)
    for (0..128) |i| {
        desc1.setBit(i);
        desc2.setBit(i + 128);
    }

    // Should have normalized distance of 1.0 (all 256 bits differ)
    try expectEqual(@as(f32, 1.0), desc1.normalizedDistance(desc2));
}

test "BinaryDescriptor equality" {
    var desc1 = BinaryDescriptor.init();
    var desc2 = BinaryDescriptor.init();

    try expectEqual(true, desc1.equals(desc2));

    desc1.setBit(42);
    try expectEqual(false, desc1.equals(desc2));

    desc2.setBit(42);
    try expectEqual(true, desc1.equals(desc2));
}

test "BinaryDescriptor random generation" {
    var prng = std.Random.DefaultPrng.init(12345);
    const rng = prng.random();

    const desc1 = BinaryDescriptor.random(rng);
    const desc2 = BinaryDescriptor.random(rng);

    // Random descriptors should be different
    try expectEqual(false, desc1.equals(desc2));

    // Should have roughly half bits set (with some variance)
    const pop1 = desc1.popCount();
    const pop2 = desc2.popCount();

    // Roughly 128 bits set (±64 for randomness)
    try expectEqual(true, pop1 > 64 and pop1 < 192);
    try expectEqual(true, pop2 > 64 and pop2 < 192);
}

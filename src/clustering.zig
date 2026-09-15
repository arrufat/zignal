//! Chinese Whispers clustering, ported from
//! [dlib](https://dlib.net/dlib/clustering/chinese_whispers.h.html).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;

const parallel = @import("parallel.zig");

pub const Error = error{
    OutOfMemory,
    /// `threshold` is negative or not finite.
    InvalidThreshold,
    /// `labels` does not have one entry per embedding.
    LabelCountMismatch,
    /// The embeddings are not all the same length.
    DimensionMismatch,
};

/// Inputs to `chineseWhispers`. `threshold` has no default because the right value depends on the
/// embedding space; the tuning knobs default to dlib's.
pub const Options = struct {
    /// Maximum Euclidean distance for two embeddings to be connected.
    threshold: f64,
    /// Passes over the graph. Each pass updates as many randomly chosen nodes as there are nodes.
    iterations: u32 = 100,
    /// Seed for the node visit order.
    seed: u64 = 0,
};

/// Clusters `embeddings` by connecting every pair closer than `options.threshold` and propagating
/// labels over that graph. Returns the number of clusters; ids are contiguous from 0, and an
/// embedding with no neighbour within the threshold ends up alone in its own cluster.
///
/// The O(n^2 * dim) pairwise pass runs in row bands on `io` and allocates per band, so
/// `allocator` must be thread-safe; propagation is sequential.
pub fn chineseWhispers(
    comptime T: type,
    io: Io,
    allocator: Allocator,
    /// One slice per embedding; all must be the same length.
    embeddings: []const []const T,
    /// Receives one cluster id per embedding.
    labels: []u32,
    options: Options,
) Error!u32 {
    if (!std.math.isFinite(options.threshold) or options.threshold < 0) return error.InvalidThreshold;
    if (labels.len != embeddings.len) return error.LabelCountMismatch;
    const n: u32 = @intCast(embeddings.len);
    if (n == 0) return 0;
    for (embeddings[1..]) |row| {
        if (row.len != embeddings[0].len) return error.DimensionMismatch;
    }

    const neighbors = try findNeighbors(T, io, allocator, embeddings, options.threshold);
    defer {
        for (neighbors) |*list| list.deinit(allocator);
        allocator.free(neighbors);
    }

    // Compressed sparse row adjacency, each pair stored in both directions. Degrees are counted
    // two slots ahead so that `offsets[i + 1]` doubles as node i's fill cursor: once it has
    // advanced to the end of node i, its neighbours are `targets[offsets[i]..offsets[i + 1]]`.
    const offsets = try allocator.alloc(u32, n + 2);
    defer allocator.free(offsets);
    @memset(offsets, 0);
    for (neighbors) |band| for (band.items) |pair| {
        offsets[pair.a + 2] += 1;
        offsets[pair.b + 2] += 1;
    };
    for (1..offsets.len) |i| offsets[i] += offsets[i - 1];

    const targets = try allocator.alloc(u32, offsets[n + 1]);
    defer allocator.free(targets);
    for (neighbors) |band| for (band.items) |pair| {
        targets[offsets[pair.a + 1]] = pair.b;
        targets[offsets[pair.b + 1]] = pair.a;
        offsets[pair.a + 1] += 1;
        offsets[pair.b + 1] += 1;
    };

    for (labels, 0..) |*label, i| label.* = @intCast(i);

    // `touched` keeps the reset O(degree) rather than O(n).
    const tally = try allocator.alloc(u32, n);
    defer allocator.free(tally);
    @memset(tally, 0);
    const touched = try allocator.alloc(u32, n);
    defer allocator.free(touched);

    var prng: std.Random.DefaultPrng = .init(options.seed);
    const rand = prng.random();
    for (0..@as(u64, n) * options.iterations) |_| {
        const idx = rand.uintLessThan(u32, n);

        var num_touched: u32 = 0;
        for (targets[offsets[idx]..offsets[idx + 1]]) |target| {
            const label = labels[target];
            if (tally[label] == 0) {
                touched[num_touched] = label;
                num_touched += 1;
            }
            tally[label] += 1;
        }

        // Ties go to the smaller label id, the order dlib's std::map scan settles them in.
        var best_label = labels[idx];
        var best_count: u32 = 0;
        for (touched[0..num_touched]) |label| {
            if (tally[label] > best_count or (tally[label] == best_count and label < best_label)) {
                best_count = tally[label];
                best_label = label;
            }
            tally[label] = 0;
        }
        labels[idx] = best_label;
    }

    // `tally` is all zeros again; reuse it to renumber the labels by first appearance.
    var num_clusters: u32 = 0;
    for (labels) |*label| {
        if (tally[label.*] == 0) {
            num_clusters += 1;
            tally[label.*] = num_clusters;
        }
        label.* = tally[label.*] - 1;
    }
    return num_clusters;
}

const Pair = struct { a: u32, b: u32 };

/// Every pair of embeddings within `threshold`. The total is not known ahead of time, so each
/// band grows its own list.
fn findNeighbors(
    comptime T: type,
    io: Io,
    allocator: Allocator,
    embeddings: []const []const T,
    threshold: f64,
) ![]ArrayList(Pair) {
    const n = embeddings.len;
    // Row i costs n-1-i, so even row bands would leave band 0 with a quarter of the work. Pairing
    // row i with row n-1-i makes every band cost the same, since the two always sum to n-1.
    const half = (n + 1) / 2;
    const bands = parallel.bandCount(half, n * embeddings[0].len);
    const lists = try allocator.alloc(ArrayList(Pair), bands);
    @memset(lists, .empty);
    errdefer {
        for (lists) |*list| list.deinit(allocator);
        allocator.free(lists);
    }

    const Ctx = struct {
        embeddings: []const []const T,
        lists: []ArrayList(Pair),
        allocator: Allocator,
        limit: f64,

        fn band(c: @This(), index: usize, row_start: usize, row_end: usize) !void {
            const list = &c.lists[index];
            for (row_start..row_end) |i| {
                try c.scanRow(list, i);
                const mirror = c.embeddings.len - 1 - i;
                if (mirror > i) try c.scanRow(list, mirror);
            }
        }

        fn scanRow(c: @This(), list: *ArrayList(Pair), i: usize) !void {
            const a = c.embeddings[i];
            for (i + 1..c.embeddings.len) |j| {
                if (withinDistance(T, a, c.embeddings[j], c.limit)) {
                    try list.append(c.allocator, .{ .a = @intCast(i), .b = @intCast(j) });
                }
            }
        }
    };
    const ctx: Ctx = .{ .embeddings = embeddings, .lists = lists, .allocator = allocator, .limit = threshold * threshold };
    try parallel.forRowBandsTry(io, half, bands, ctx, Ctx.band);

    return lists;
}

/// Whether the squared Euclidean distance between `a` and `b` stays below `limit`. Tests the
/// running sum every `block` elements and bails out early: a threshold that rejects most pairs
/// usually settles them in the first few dimensions, and every term is non-negative, so the
/// answer matches summing all of them. Each block accumulates in `T` across lanes (a serial
/// `sum += d * d` chain is reassociation-bound and will not auto-vectorize) and widens once.
fn withinDistance(comptime T: type, a: []const T, b: []const T, limit: f64) bool {
    const lanes = std.simd.suggestVectorLength(T) orelse 1;
    // 16 elements settle most rejected pairs; a wider block only delays the exit.
    const block = @max(16, lanes);
    var sum: f64 = 0;
    var i: usize = 0;
    while (i < a.len) {
        const end = @min(i + block, a.len);
        var acc: @Vector(lanes, T) = @splat(0);
        while (i + lanes <= end) : (i += lanes) {
            const av: @Vector(lanes, T) = a[i..][0..lanes].*;
            const bv: @Vector(lanes, T) = b[i..][0..lanes].*;
            const d = av - bv;
            acc += d * d;
        }
        var partial: T = @reduce(.Add, acc);
        for (a[i..end], b[i..end]) |x, y| {
            const d = x - y;
            partial += d * d;
        }
        sum += partial;
        i = end;
        if (sum >= limit) return false;
    }
    return sum < limit;
}

// ---- Tests ----

/// Two well-separated blobs of three points each, in the plane.
const blobs: []const []const f64 = &.{
    &.{ 0.0, 0.0 }, &.{ 0.1, 0.2 }, &.{ 0.2, 0.0 },
    &.{ 9.0, 9.0 }, &.{ 9.1, 9.2 }, &.{ 9.2, 9.0 },
};

fn cluster(embeddings: []const []const f64, threshold: f64, labels: []u32) !u32 {
    return chineseWhispers(f64, parallel.inline_io, std.testing.allocator, embeddings, labels, .{ .threshold = threshold });
}

test "chineseWhispers separates two blobs" {
    var labels: [6]u32 = undefined;
    try expectEqual(2, try cluster(blobs, 1.0, &labels));
    try expectEqualSlices(u32, &.{ 0, 0, 0, 1, 1, 1 }, &labels);
}

test "chineseWhispers leaves lone embeddings in their own cluster" {
    var labels: [6]u32 = undefined;
    try expectEqual(6, try cluster(blobs, 0.01, &labels));
    try expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5 }, &labels);

    const outlier: []const []const f64 = &.{ &.{ 0.0, 0.0 }, &.{ 0.1, 0.1 }, &.{ 50.0, 50.0 } };
    var three: [3]u32 = undefined;
    try expectEqual(2, try cluster(outlier, 1.0, &three));
    try expectEqualSlices(u32, &.{ 0, 0, 1 }, &three);
}

test "chineseWhispers merges everything above the largest distance" {
    var labels: [6]u32 = undefined;
    try expectEqual(1, try cluster(blobs, 100.0, &labels));
    try expectEqualSlices(u32, &.{ 0, 0, 0, 0, 0, 0 }, &labels);
}

test "chineseWhispers handles the empty and single-embedding cases" {
    var none: [0]u32 = undefined;
    try expectEqual(0, try cluster(&.{}, 1.0, &none));

    var one: [1]u32 = undefined;
    try expectEqual(1, try cluster(&.{&.{ 1.0, 2.0 }}, 1.0, &one));
    try expectEqual(0, one[0]);
}

test "chineseWhispers rejects malformed input" {
    var labels: [6]u32 = undefined;
    try expectError(error.InvalidThreshold, cluster(blobs, -1, &labels));
    try expectError(error.InvalidThreshold, cluster(blobs, std.math.inf(f64), &labels));

    var wrong: [3]u32 = undefined;
    try expectError(error.LabelCountMismatch, cluster(blobs, 1.0, &wrong));

    const ragged: []const []const f64 = &.{ &.{ 0.0, 1.0 }, &.{2.0} };
    var two: [2]u32 = undefined;
    try expectError(error.DimensionMismatch, cluster(ragged, 1.0, &two));
}

test "chineseWhispers clusters f32 embeddings of realistic width" {
    const allocator = std.testing.allocator;
    const dim = 128;
    const per_cluster = 40;
    const planted = 4;

    var prng: std.Random.DefaultPrng = .init(0xE1BE);
    const rand = prng.random();
    const storage = try allocator.alloc([dim]f32, planted * per_cluster);
    defer allocator.free(storage);
    const embeddings = try allocator.alloc([]const f32, storage.len);
    defer allocator.free(embeddings);
    for (storage, embeddings, 0..) |*point, *row, i| {
        const center: f32 = @floatFromInt((i / per_cluster) * 10);
        for (point) |*v| v.* = center + (rand.float(f32) - 0.5) * 0.01;
        row.* = point;
    }

    const labels = try allocator.alloc(u32, embeddings.len);
    defer allocator.free(labels);

    var threaded: Io.Threaded = .init(allocator, .{ .async_limit = .limited(8) });
    defer threaded.deinit();

    try expectEqual(planted, try chineseWhispers(f32, threaded.io(), allocator, embeddings, labels, .{ .threshold = 1.0 }));
    for (labels, 0..) |label, i| try expectEqual(i / per_cluster, label);

    const serial = try allocator.alloc(u32, embeddings.len);
    defer allocator.free(serial);
    _ = try chineseWhispers(f32, parallel.inline_io, allocator, embeddings, serial, .{ .threshold = 1.0 });
    try expectEqualSlices(u32, labels, serial);
}

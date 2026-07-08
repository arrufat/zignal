//! QR code detector: locates a symbol in a grayscale image and decodes it.
//! Handles photographs — perspective distortion, uneven lighting, moderate
//! blur — as well as clean generated images, in any of the four rotations,
//! mirrored or not. Supported down to roughly 2 pixels per module.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ProjectiveTransform = @import("../geometry.zig").ProjectiveTransform;
const Point = @import("../geometry/Point.zig").Point;
const Image = @import("../image.zig").Image;
const decoder = @import("decoder.zig");
const DecodeResult = decoder.DecodeResult;
const tables = @import("tables.zig");

/// Run-ratio tolerance for the initial row scan (fraction of a module).
const scan_tolerance = 0.5;
/// Looser tolerance for cross-checks so blur doesn't kill recall.
const cross_tolerance = 0.7;
/// The diagonal check only guards against dense-data false positives.
const diag_tolerance = 0.8;

/// Locates a QR code in a grayscale image (clean or photographed) and decodes
/// it. Returns null when no decodable QR code is found. Caller owns result.data.
pub fn decode(allocator: Allocator, image: Image(u8)) !?DecodeResult {
    if (image.rows < 21 or image.cols < 21) return null;

    var binary = try Image(u8).initLike(allocator, image);
    defer binary.deinit(allocator);

    // Adaptive thresholding handles the uneven lighting of photos; Otsu is
    // the retry because large flat regions (clean images, big modules) can
    // hollow out under a local mean.
    for (0..2) |pass| {
        if (pass == 0) {
            const radius = @max(@min(image.rows, image.cols) / 16, 8);
            image.thresholdAdaptiveMean(binary, allocator, radius, 4) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
        } else {
            _ = image.thresholdOtsu(binary, allocator) catch continue;
        }
        if (try detectAndDecode(allocator, binary)) |result| return result;
    }
    return null;
}

fn detectAndDecode(allocator: Allocator, binary: Image(u8)) !?DecodeResult {
    var finders_buf: [64]FinderPattern = undefined;
    const row_step: usize = if (binary.rows > 300) 3 else 1;
    var finders = findFinderPatterns(binary, row_step, &finders_buf);
    if (finders.len < 3 and row_step > 1) {
        finders = findFinderPatterns(binary, 1, &finders_buf);
    }
    if (finders.len < 3) return null;
    // A real finder is re-detected on several scan rows; data-region false
    // positives usually confirm once. Drop single-hit candidates when enough
    // multiply-confirmed ones remain.
    var confirmed: usize = 0;
    for (finders) |f| {
        if (f.hits >= 2) {
            finders_buf[confirmed] = f;
            confirmed += 1;
        }
    }
    if (confirmed >= 3) finders = finders_buf[0..confirmed];
    const triple = pickFinderTriple(finders) orelse return null;

    var candidates: [8]u8 = undefined;
    var count: usize = 0;
    const estimate = estimateVersion(triple);
    appendCandidate(&candidates, &count, estimate);
    if (estimate > tables.min_version) appendCandidate(&candidates, &count, estimate - 1);
    if (estimate < tables.max_version) appendCandidate(&candidates, &count, estimate + 1);

    const max_dim: usize = tables.dimension(tables.max_version);
    const modules = try allocator.alloc(u8, max_dim * max_dim);
    defer allocator.free(modules);

    // The alignment pattern's image-space position does not depend on the
    // assumed version, so search once (sized by the largest initial
    // candidate) and share the hits across all version candidates.
    var fourth_buf: [5]Fourth = undefined;
    const scan_version = @min(estimate + 1, tables.max_version);
    const fourths = fourthCandidates(binary, triple, tables.dimension(scan_version), &fourth_buf);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const version = candidates[i];
        const dim = tables.dimension(version);
        const grid = modules[0 .. @as(usize, dim) * dim];
        for (fourths) |fourth| {
            // Version 1 has no alignment pattern.
            if (fourth.is_alignment and version < 2) continue;
            const transform = buildTransform(triple, dim, fourth) orelse continue;
            if (!sampleGrid(binary, transform, dim, grid)) continue;
            if (!timingOk(grid, dim)) continue;
            // The symbol's own version information beats the geometric estimate.
            if (version >= 7) {
                if (decoder.readVersion(grid, dim)) |hint| {
                    appendCandidate(&candidates, &count, hint);
                }
            }
            if (decoder.decodeModules(allocator, version, grid)) |result| {
                return result;
            } else |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
            }
        }
    }
    return null;
}

fn appendCandidate(candidates: []u8, count: *usize, version: u8) void {
    for (candidates[0..count.*]) |existing| {
        if (existing == version) return;
    }
    if (count.* < candidates.len) {
        candidates[count.*] = version;
        count.* += 1;
    }
}

fn isDark(binary: Image(u8), row: usize, col: usize) bool {
    return binary.at(row, col).* == 0;
}

const FinderPattern = struct {
    /// Center in image space (x = column, y = row).
    center: Point(2, f32),
    module_size: f32,
    hits: f32,
};

/// Scans rows for the 1:1:3:1:1 finder ratio and cross-checks each candidate
/// on both axes and the diagonal. Duplicate detections are merged.
fn findFinderPatterns(binary: Image(u8), row_step: usize, buf: []FinderPattern) []FinderPattern {
    var count: usize = 0;
    var row: usize = 0;
    while (row < binary.rows) : (row += row_step) {
        var runs: [5]usize = @splat(0);
        var run_value = isDark(binary, row, 0);
        var run_len: usize = 0;
        var col: usize = 0;
        while (col <= binary.cols) : (col += 1) {
            const value = if (col < binary.cols) isDark(binary, row, col) else !run_value;
            if (value == run_value) {
                run_len += 1;
                continue;
            }
            // A run just ended; shift it into the 5-run window. The window is
            // checked whenever a dark run ends, so it holds the pattern's
            // dark-light-dark-light-dark sequence.
            std.mem.copyForwards(usize, runs[0..4], runs[1..5]);
            runs[4] = run_len;
            if (run_value and checkRatio(runs, scan_tolerance)) {
                const mid_start = col - runs[4] - runs[3] - runs[2];
                if (confirmCandidate(binary, row, mid_start + runs[2] / 2)) |pattern| {
                    addCandidate(buf, &count, pattern);
                }
            }
            run_value = value;
            run_len = 1;
        }
    }
    return buf[0..count];
}

fn checkRatio(runs: [5]usize, tolerance: f32) bool {
    var total: usize = 0;
    for (runs) |r| {
        if (r == 0) return false;
        total += r;
    }
    if (total < 7) return false;
    const unit = @as(f32, @floatFromInt(total)) / 7.0;
    for (runs, [5]f32{ 1, 1, 3, 1, 1 }) |run, expected| {
        const width: f32 = @floatFromInt(run);
        if (@abs(width - expected * unit) > expected * unit * tolerance) return false;
    }
    return true;
}

/// Traces the dark-light-dark run sequence starting at (start_row, start_col)
/// and stepping by (d_row, d_col). Returns the run lengths from the starting
/// (dark) run outward, or null if the outer runs are missing.
fn traceRuns(binary: Image(u8), start_row: i64, start_col: i64, d_row: i64, d_col: i64) ?[3]usize {
    var runs: [3]usize = @splat(0);
    var state: usize = 0;
    var r = start_row;
    var c = start_col;
    while (r >= 0 and r < binary.rows and c >= 0 and c < binary.cols) : ({
        r += d_row;
        c += d_col;
    }) {
        const dark = isDark(binary, @intCast(r), @intCast(c));
        if (dark != (state != 1)) {
            if (state == 2) break;
            state += 1;
            // Re-examine this pixel as part of the next run.
            r -= d_row;
            c -= d_col;
            continue;
        }
        runs[state] += 1;
    }
    if (runs[1] == 0 or runs[2] == 0) return null;
    return runs;
}

const Cross = struct {
    total: usize,
    /// Pixels covered by the forward trace (from the base pixel's successor).
    forward: usize,
};

/// Traces the five finder runs through (row, col) along (d_row, d_col):
/// backward from the base pixel and forward from its successor, splicing the
/// two dark-light-dark halves into the 1:1:3:1:1 window.
fn crossCheck(binary: Image(u8), row: i64, col: i64, d_row: i64, d_col: i64, tolerance: f32) ?Cross {
    const back = traceRuns(binary, row, col, -d_row, -d_col) orelse return null;
    const fwd = traceRuns(binary, row + d_row, col + d_col, d_row, d_col) orelse return null;
    const runs: [5]usize = .{ back[2], back[1], back[0] + fwd[0], fwd[1], fwd[2] };
    if (!checkRatio(runs, tolerance)) return null;
    var total: usize = 0;
    for (runs) |run| total += run;
    return .{ .total = total, .forward = fwd[0] + fwd[1] + fwd[2] };
}

/// Cross-checks a row-scan candidate vertically, horizontally, and
/// diagonally, refining the center from the full 7-module extents.
fn confirmCandidate(binary: Image(u8), row: usize, col: usize) ?FinderPattern {
    if (col >= binary.cols or !isDark(binary, row, col)) return null;

    const vertical = crossCheck(binary, @intCast(row), @intCast(col), 1, 0, cross_tolerance) orelse return null;
    // The pattern's exclusive bottom edge minus half its extent.
    const center_row = @as(f32, @floatFromInt(row + 1 + vertical.forward)) -
        @as(f32, @floatFromInt(vertical.total)) / 2.0;

    const crow: i64 = @intFromFloat(center_row);
    if (!isDark(binary, @intCast(crow), col)) return null;
    const horizontal = crossCheck(binary, crow, @intCast(col), 0, 1, cross_tolerance) orelse return null;
    const center_col = @as(f32, @floatFromInt(col + 1 + horizontal.forward)) -
        @as(f32, @floatFromInt(horizontal.total)) / 2.0;

    // Loose diagonal check to reject finder-like data noise.
    const ccol: i64 = @intFromFloat(center_col);
    if (!isDark(binary, @intCast(crow), @intCast(ccol))) return null;
    _ = crossCheck(binary, crow, ccol, 1, 1, diag_tolerance) orelse return null;

    return .{
        .center = .init(.{ center_col, center_row }),
        .module_size = @as(f32, @floatFromInt(vertical.total + horizontal.total)) / 14.0,
        .hits = 1,
    };
}

fn addCandidate(buf: []FinderPattern, count: *usize, pattern: FinderPattern) void {
    for (buf[0..count.*]) |*existing| {
        const near = 2 * existing.module_size;
        const diff = existing.center.sub(pattern.center);
        if (@abs(diff.x()) < near and @abs(diff.y()) < near) {
            // Merge as a running average weighted by prior hits.
            const w = existing.hits;
            existing.center = existing.center.scale(w).add(pattern.center).scale(1 / (w + 1));
            existing.module_size = (existing.module_size * w + pattern.module_size) / (w + 1);
            existing.hits += 1;
            return;
        }
    }
    if (count.* < buf.len) {
        buf[count.*] = pattern;
        count.* += 1;
    }
}

const FinderTriple = struct {
    top_left: FinderPattern,
    top_right: FinderPattern,
    bottom_left: FinderPattern,

    fn moduleSize(self: FinderTriple) f32 {
        return (self.top_left.module_size + self.top_right.module_size +
            self.bottom_left.module_size) / 3;
    }
};

/// Chooses the three patterns forming the best right angle (any rotation)
/// with consistent module sizes, and labels the corners: top-left is the
/// right-angle vertex, top-right vs bottom-left by cross product sign.
fn pickFinderTriple(finders: []const FinderPattern) ?FinderTriple {
    var best_score: f32 = std.math.floatMax(f32);
    var best: ?FinderTriple = null;
    for (finders, 0..) |a, i| {
        for (finders[i + 1 ..], i + 1..) |b, j| {
            for (finders[j + 1 ..]) |c| {
                const ms_max = @max(a.module_size, @max(b.module_size, c.module_size));
                const ms_min = @min(a.module_size, @min(b.module_size, c.module_size));
                if (ms_max > 1.6 * ms_min) continue;
                const ms = (a.module_size + b.module_size + c.module_size) / 3;

                // The top-left corner is opposite the longest side.
                const ab = a.center.distance(b.center);
                const ac = a.center.distance(c.center);
                const bc = b.center.distance(c.center);
                var corner = c;
                var m1 = a;
                var m2 = b;
                if (bc >= ab and bc >= ac) {
                    corner = a;
                    m1 = b;
                    m2 = c;
                } else if (ac >= ab and ac >= bc) {
                    corner = b;
                    m1 = a;
                    m2 = c;
                }

                const v1 = m1.center.sub(corner.center);
                const v2 = m2.center.sub(corner.center);
                const len1 = v1.norm();
                const len2 = v2.norm();
                if (@min(len1, len2) < 10 * ms) continue;
                const imbalance = @abs(len1 - len2) / @max(len1, len2);
                if (imbalance > 0.35) continue;
                const cos = v1.dot(v2) / (len1 * len2);
                if (@abs(cos) > 0.35) continue;

                // With x = col and y = row (y down), module space has
                // cross(TL->TR, TL->BL) > 0; a mirrored photo picks the
                // "wrong" handedness, recovered by decodeModules' mirrored
                // orientations.
                const triple: FinderTriple = if (v1.cross(v2) > 0)
                    .{ .top_left = corner, .top_right = m1, .bottom_left = m2 }
                else
                    .{ .top_left = corner, .top_right = m2, .bottom_left = m1 };

                const score = (ms_max - ms_min) / ms + imbalance + @abs(cos);
                if (score < best_score) {
                    best_score = score;
                    best = triple;
                }
            }
        }
    }
    return best;
}

fn estimateVersion(triple: FinderTriple) u8 {
    const side = (triple.top_left.center.distance(triple.top_right.center) +
        triple.top_left.center.distance(triple.bottom_left.center)) / 2;
    const dim_est = side / triple.moduleSize() + 7;
    const version = @round((dim_est - 17) / 4);
    return @intFromFloat(std.math.clamp(version, tables.min_version, tables.max_version));
}

/// A fourth-correspondence candidate: an alignment pattern center at module
/// (dim-6.5, dim-6.5), or the parallelogram completion at (dim-3.5, dim-3.5).
const Fourth = struct {
    center: Point(2, f32),
    is_alignment: bool,
};

/// Builds the module-space to image-space homography from the three finder
/// centers plus a fourth correspondence.
fn buildTransform(triple: FinderTriple, dim: u16, fourth: Fourth) ?ProjectiveTransform(f64) {
    const d: f64 = @floatFromInt(dim);
    // The bottom-right alignment center sits at (dim - 6.5): Annex E pins the
    // last alignment coordinate to dim - 7, an invariant tested in tables.zig.
    const module: f64 = if (fourth.is_alignment) d - 6.5 else d - 3.5;
    const from: [4]Point(2, f64) = .{
        .init(.{ 3.5, 3.5 }),
        .init(.{ d - 3.5, 3.5 }),
        .init(.{ 3.5, d - 3.5 }),
        .init(.{ module, module }),
    };
    const to: [4]Point(2, f64) = .{
        .init(.{ triple.top_left.center.x(), triple.top_left.center.y() }),
        .init(.{ triple.top_right.center.x(), triple.top_right.center.y() }),
        .init(.{ triple.bottom_left.center.x(), triple.bottom_left.center.y() }),
        .init(.{ fourth.center.x(), fourth.center.y() }),
    };
    return ProjectiveTransform(f64).initExact(from, to);
}

/// Collects fourth-correspondence candidates: alignment pattern hits around
/// the affine prediction ordered nearest first, then the parallelogram
/// completion as the final fallback. The affine prediction ignores
/// perspective, whose error grows with the version, so wrong-but-nearer
/// candidates are possible; the caller validates each downstream.
fn fourthCandidates(binary: Image(u8), triple: FinderTriple, dim: u16, buf: *[5]Fourth) []Fourth {
    var count: usize = 0;
    if (dim >= tables.dimension(2)) {
        const span: f32 = @floatFromInt(dim - 7);
        const steps: f32 = @floatFromInt(dim - 10); // modules from TL center to (dim-6.5)
        const tl = triple.top_left.center;
        const per_module = triple.top_right.center.sub(tl)
            .add(triple.bottom_left.center.sub(tl)).scale(1 / span);
        const prediction = tl.add(per_module.scale(steps));
        const ms = triple.moduleSize();

        var found: [4]Fourth = undefined;
        var found_d2: [4]f32 = undefined;
        var found_count: usize = 0;
        // Strong perspective drifts the true pattern up to ~0.2 modules per
        // extrapolated module; false hits inside the window are harmless
        // because every candidate is validated by timing and decode.
        const radius = ms * @max(5, 0.2 * steps);
        const step: f32 = @trunc(@max(1, ms / 2));
        var y = prediction.y() - radius;
        while (y <= prediction.y() + radius) : (y += step) {
            if (y < 0) continue;
            const py: usize = @intFromFloat(y);
            if (py >= binary.rows) break;
            var x = prediction.x() - radius;
            while (x <= prediction.x() + radius) : (x += step) {
                if (x < 0) continue;
                const px: usize = @intFromFloat(x);
                if (px >= binary.cols) break;
                if (!isDark(binary, py, px)) continue;
                const candidate = checkAlignment(binary, py, px, ms) orelse continue;
                const d2 = candidate.center.distanceSquared(prediction);
                insertNearest(&found, &found_d2, &found_count, candidate, d2, ms);
            }
        }
        @memcpy(buf[0..found_count], found[0..found_count]);
        count = found_count;
    }
    buf[count] = .{
        .center = triple.top_right.center.add(triple.bottom_left.center).sub(triple.top_left.center),
        .is_alignment = false,
    };
    count += 1;
    return buf[0..count];
}

/// Keeps the candidates nearest to the prediction, merging re-detections of
/// the same pattern (within one module) to the nearer measurement.
fn insertNearest(found: *[4]Fourth, found_d2: *[4]f32, found_count: *usize, candidate: Fourth, d2: f32, ms: f32) void {
    for (found[0..found_count.*], found_d2[0..found_count.*]) |*existing, *existing_d2| {
        const diff = existing.center.sub(candidate.center);
        if (@abs(diff.x()) < ms and @abs(diff.y()) < ms) {
            if (d2 < existing_d2.*) {
                existing.* = candidate;
                existing_d2.* = d2;
            }
            return;
        }
    }
    var at = found_count.*;
    while (at > 0 and d2 < found_d2[at - 1]) at -= 1;
    if (at >= found.len) return;
    var back = @min(found_count.*, found.len - 1);
    while (back > at) : (back -= 1) {
        found[back] = found[back - 1];
        found_d2[back] = found_d2[back - 1];
    }
    found[at] = candidate;
    found_d2[at] = d2;
    if (found_count.* < found.len) found_count.* += 1;
}

/// traceRuns specialized for alignment probes: gives up once a run exceeds
/// limit (it could no longer pass the ratio checks) and returns as soon as
/// the outer dark run is confirmed, bounding the cost of probes that land in
/// large dark regions.
fn traceAlignmentRuns(binary: Image(u8), start_row: i64, start_col: i64, d_row: i64, d_col: i64, limit: usize) ?[3]usize {
    var runs: [3]usize = @splat(0);
    var state: usize = 0;
    var r = start_row;
    var c = start_col;
    while (r >= 0 and r < binary.rows and c >= 0 and c < binary.cols) : ({
        r += d_row;
        c += d_col;
    }) {
        const dark = isDark(binary, @intCast(r), @intCast(c));
        if (dark != (state != 1)) {
            state += 1;
            // Re-examine this pixel as part of the next run.
            r -= d_row;
            c -= d_col;
            continue;
        }
        runs[state] += 1;
        if (state == 2) return runs;
        if (runs[state] > limit) return null;
    }
    return null;
}

/// Verifies the 1:1:1 dark-light-dark alignment signature on both axes
/// through (row, col) and refines the center from the run extents.
fn checkAlignment(binary: Image(u8), row: usize, col: usize, ms: f32) ?Fourth {
    const near = struct {
        fn near(len: usize, expected: f32) bool {
            return @abs(@as(f32, @floatFromInt(len)) - expected) <= expected * 0.6;
        }
    }.near;
    // No run of a passing candidate can exceed 1.6 modules.
    const limit: usize = @intFromFloat(ms * 1.6 + 1);

    const left = traceAlignmentRuns(binary, @intCast(row), @intCast(col), 0, -1, limit) orelse return null;
    if (!near(left[1], ms)) return null;
    const right = traceAlignmentRuns(binary, @intCast(row), @as(i64, @intCast(col)) + 1, 0, 1, limit) orelse return null;
    if (!near(left[0] + right[0], ms) or !near(right[1], ms)) return null;
    // The dark run spans [col - left[0] + 1, col + right[0]] inclusive.
    const center_col = @as(f32, @floatFromInt(col)) +
        (@as(f32, @floatFromInt(right[0])) - @as(f32, @floatFromInt(left[0]))) / 2 + 1;

    const ccol: usize = @intFromFloat(center_col);
    if (ccol >= binary.cols or !isDark(binary, row, ccol)) return null;
    const up = traceAlignmentRuns(binary, @intCast(row), @intCast(ccol), -1, 0, limit) orelse return null;
    if (!near(up[1], ms)) return null;
    const down = traceAlignmentRuns(binary, @as(i64, @intCast(row)) + 1, @intCast(ccol), 1, 0, limit) orelse return null;
    if (!near(up[0] + down[0], ms) or !near(down[1], ms)) return null;
    const center_row = @as(f32, @floatFromInt(row)) +
        (@as(f32, @floatFromInt(down[0])) - @as(f32, @floatFromInt(up[0]))) / 2 + 1;

    // Ring probes at the local scale: the diagonals at one module out sit in
    // the light ring, at two modules out on the dark ring corners. Isolated
    // dark data modules pass the axis checks but rarely this.
    const local_ms = @as(f32, @floatFromInt(left[0] + right[0] + up[0] + down[0])) / 2;
    for ([4][2]f32{ .{ 1, 1 }, .{ 1, -1 }, .{ -1, 1 }, .{ -1, -1 } }) |diag| {
        for ([2]struct { scale: f32, dark: bool }{
            .{ .scale = 1, .dark = false },
            .{ .scale = 2, .dark = true },
        }) |probe| {
            const pr = center_row + diag[0] * probe.scale * local_ms;
            const pc = center_col + diag[1] * probe.scale * local_ms;
            if (pr < 0 or pc < 0) return null;
            const pri: usize = @intFromFloat(pr);
            const pci: usize = @intFromFloat(pc);
            if (pri >= binary.rows or pci >= binary.cols) return null;
            if (isDark(binary, pri, pci) != probe.dark) return null;
        }
    }

    return .{ .center = .init(.{ center_col, center_row }), .is_alignment = true };
}

/// Projects each module center through the homography and reads the
/// binarized pixel with a 3-of-5 plus-shaped vote. Returns false if a module
/// center falls outside the image.
fn sampleGrid(binary: Image(u8), transform: ProjectiveTransform(f64), dim: u16, out: []u8) bool {
    const offsets = [5][2]f64{ .{ 0, 0 }, .{ 0.25, 0 }, .{ -0.25, 0 }, .{ 0, 0.25 }, .{ 0, -0.25 } };
    for (0..dim) |row| {
        for (0..dim) |col| {
            var votes: u32 = 0;
            for (offsets, 0..) |offset, k| {
                // Stop once the vote is decided either way.
                if (votes >= 3 or votes + (offsets.len - k) < 3) break;
                const p = transform.project(.init(.{
                    @as(f64, @floatFromInt(col)) + 0.5 + offset[0],
                    @as(f64, @floatFromInt(row)) + 0.5 + offset[1],
                }));
                const in_bounds = p.x() >= 0 and p.y() >= 0 and
                    p.x() < @as(f64, @floatFromInt(binary.cols)) and
                    p.y() < @as(f64, @floatFromInt(binary.rows));
                if (!in_bounds) {
                    if (k == 0) return false;
                    continue; // off-center votes outside the image count as light
                }
                const px: usize = @intFromFloat(p.x());
                const py: usize = @intFromFloat(p.y());
                if (isDark(binary, py, px)) votes += 1;
            }
            out[row * dim + col] = @intFromBool(votes >= 3);
        }
    }
    return true;
}

/// Orientation-agnostic timing check: the two timing lines land on row 6 or
/// dim-7 and column 6 or dim-7 depending on rotation; the best line on each
/// axis must match the expected alternation on at least 75% of its modules.
fn timingOk(modules: []const u8, dim: u16) bool {
    const lines = [2]usize{ 6, dim - 7 };
    var row_best: usize = 0;
    var col_best: usize = 0;
    for (lines) |line| {
        var row_match: usize = 0;
        var col_match: usize = 0;
        for (8..dim - 8) |i| {
            const expected: u8 = @intFromBool(i % 2 == 0);
            if (modules[line * dim + i] == expected) row_match += 1;
            if (modules[i * dim + line] == expected) col_match += 1;
        }
        row_best = @max(row_best, row_match);
        col_best = @max(col_best, col_match);
    }
    const needed = (@as(usize, dim) - 16) * 3 / 4;
    return row_best >= needed and col_best >= needed;
}

// -- Tests --------------------------------------------------------------

const encoder = @import("encoder.zig");
const perlin = @import("../perlin.zig").perlin;

/// Renders a clean QR image into a destination quadrilateral with optional
/// lighting gradient, perlin shading, blur, and pixel noise — a synthetic
/// stand-in for a photographed code.
fn photoSimulate(allocator: Allocator, clean: Image(u8), opts: struct {
    /// Destination corners (x, y) of the source image: TL, TR, BL, BR.
    corners: [4][2]f32,
    out_rows: u32,
    out_cols: u32,
    sigma: f32 = 0,
    ramp: f32 = 0,
    perlin_amp: f32 = 0,
    noise: f32 = 0,
    seed: u64 = 0x5eed,
}) !Image(u8) {
    var out = try Image(u8).init(allocator, opts.out_rows, opts.out_cols);
    errdefer out.deinit(allocator);

    // Image.warp uses backward mapping, so the transform goes output -> source.
    const w: f64 = @floatFromInt(clean.cols - 1);
    const h: f64 = @floatFromInt(clean.rows - 1);
    const source = [4]Point(2, f64){
        .init(.{ 0, 0 }), .init(.{ w, 0 }), .init(.{ 0, h }), .init(.{ w, h }),
    };
    var destination: [4]Point(2, f64) = undefined;
    for (opts.corners, 0..) |corner, i| {
        destination[i] = .init(.{ corner[0], corner[1] });
    }
    const transform = ProjectiveTransform(f64).initExact(destination, source) orelse return error.DegenerateCorners;
    const t32 = transform.as(f32);
    clean.warp(out, t32, .bilinear);
    // warp's mirror border tiles reflected copies of the source across the
    // canvas; pixels mapping outside the source are quiet-zone white.
    for (0..out.rows) |r| {
        for (0..out.cols) |c| {
            const p = t32.project(.init(.{
                @as(f32, @floatFromInt(c)),
                @as(f32, @floatFromInt(r)),
            }));
            if (p.x() < 0 or p.y() < 0 or p.x() > w or p.y() > h) out.at(r, c).* = 255;
        }
    }

    var prng: std.Random.DefaultPrng = .init(opts.seed);
    const random = prng.random();
    const cols: f32 = @floatFromInt(out.cols);
    const rows: f32 = @floatFromInt(out.rows);
    for (0..out.rows) |r| {
        for (0..out.cols) |c| {
            var value: f32 = @floatFromInt(out.at(r, c).*);
            const fx = @as(f32, @floatFromInt(c)) / cols;
            const fy = @as(f32, @floatFromInt(r)) / rows;
            value += opts.ramp * (fx - 0.5) * 2;
            if (opts.perlin_amp != 0) {
                value += opts.perlin_amp * perlin(f32, 4 * fx, 4 * fy, 0.5, .{});
            }
            if (opts.noise != 0) {
                value += (random.float(f32) - 0.5) * 2 * opts.noise;
            }
            out.at(r, c).* = @intFromFloat(std.math.clamp(value, 0, 255));
        }
    }

    if (opts.sigma > 0) {
        var blurred = try Image(u8).initLike(allocator, out);
        errdefer blurred.deinit(allocator);
        try out.gaussianBlur(blurred, allocator, opts.sigma);
        out.deinit(allocator);
        return blurred;
    }
    return out;
}

fn expectDecodes(allocator: Allocator, image: Image(u8), expected: []const u8) !void {
    var result = (try decode(allocator, image)) orelse return error.TestUnexpectedResult;
    defer result.deinit(allocator);
    try std.testing.expectEqualSlices(u8, expected, result.data);
}

test "image roundtrip across module sizes and quiet zones" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { module_size: u32, quiet_zone: u32 }{
        .{ .module_size = 1, .quiet_zone = 4 },
        .{ .module_size = 3, .quiet_zone = 4 },
        .{ .module_size = 8, .quiet_zone = 0 },
    };
    for (cases) |c| {
        var image = try encoder.encodeImage(allocator, "https://github.com/arrufat/zignal", .{
            .module_size = c.module_size,
            .quiet_zone = c.quiet_zone,
        });
        defer image.deinit(allocator);
        try expectDecodes(allocator, image, "https://github.com/arrufat/zignal");
    }
}

test "decode returns null on blank and noise images" {
    const allocator = std.testing.allocator;
    var blank = try Image(u8).init(allocator, 64, 64);
    defer blank.deinit(allocator);
    blank.fill(255);
    try std.testing.expectEqual(@as(?DecodeResult, null), try decode(allocator, blank));

    var prng: std.Random.DefaultPrng = .init(1);
    prng.random().bytes(blank.data);
    if (try decode(allocator, blank)) |result| {
        var r = result;
        r.deinit(allocator);
        return error.TestUnexpectedResult;
    }
}

test "decode rotated 30 degrees" {
    const allocator = std.testing.allocator;
    var clean = try encoder.encodeImage(allocator, "ROTATED THIRTY", .{ .module_size = 6 });
    defer clean.deinit(allocator);

    // Rotate the source square around the canvas center.
    const side: f32 = @floatFromInt(clean.cols);
    const canvas: f32 = side * 1.6;
    const cos = @cos(std.math.pi / 6.0);
    const sin = @sin(std.math.pi / 6.0);
    var corners: [4][2]f32 = undefined;
    const half = side / 2;
    const src_corners = [4][2]f32{ .{ -half, -half }, .{ half, -half }, .{ -half, half }, .{ half, half } };
    for (src_corners, 0..) |corner, i| {
        corners[i] = .{
            canvas / 2 + cos * corner[0] - sin * corner[1],
            canvas / 2 + sin * corner[0] + cos * corner[1],
        };
    }
    var photo = try photoSimulate(allocator, clean, .{
        .corners = corners,
        .out_rows = @intFromFloat(canvas),
        .out_cols = @intFromFloat(canvas),
    });
    defer photo.deinit(allocator);
    try expectDecodes(allocator, photo, "ROTATED THIRTY");
}

test "decode under perspective distortion" {
    const allocator = std.testing.allocator;
    // v7 exercises the alignment-pattern fourth corner and version info.
    // Versions are forced: v1 (no alignment pattern) cannot correct this
    // much perspective, and short alphanumeric payloads would fit v1.
    const payloads = [_]struct { data: []const u8, version: ?u8 }{
        .{ .data = "PERSPECTIVE V2 TEST", .version = 2 },
        .{ .data = "PERSPECTIVE VERSION SEVEN WITH LONGER PAYLOAD FOR SIZE", .version = 7 },
    };
    for (payloads) |payload| {
        var clean = try encoder.encodeImage(allocator, payload.data, .{
            .module_size = 8,
            .version = payload.version,
        });
        defer clean.deinit(allocator);
        const side: f32 = @floatFromInt(clean.cols);
        // Corners displaced inward by 10-15% on different edges (keystone).
        var photo = try photoSimulate(allocator, clean, .{
            .corners = .{
                .{ side * 0.15, side * 0.10 },
                .{ side * 1.05, side * 0.02 },
                .{ side * 0.05, side * 1.02 },
                .{ side * 1.15, side * 1.12 },
            },
            .out_rows = @intFromFloat(side * 1.25),
            .out_cols = @intFromFloat(side * 1.25),
        });
        defer photo.deinit(allocator);
        try expectDecodes(allocator, photo, payload.data);
    }
}

test "decode mirrored perspective" {
    const allocator = std.testing.allocator;
    var clean = try encoder.encodeImage(allocator, "MIRRORED", .{ .module_size = 8, .version = 2 });
    defer clean.deinit(allocator);
    const side: f32 = @floatFromInt(clean.cols);
    // Swap left and right destination corners to mirror the symbol.
    var photo = try photoSimulate(allocator, clean, .{
        .corners = .{
            .{ side * 1.05, side * 0.08 },
            .{ side * 0.10, side * 0.02 },
            .{ side * 1.12, side * 1.04 },
            .{ side * 0.04, side * 1.10 },
        },
        .out_rows = @intFromFloat(side * 1.2),
        .out_cols = @intFromFloat(side * 1.2),
    });
    defer photo.deinit(allocator);
    try expectDecodes(allocator, photo, "MIRRORED");
}

test "decode under uneven lighting" {
    const allocator = std.testing.allocator;
    var clean = try encoder.encodeImage(allocator, "UNEVEN LIGHTING", .{ .module_size = 6 });
    defer clean.deinit(allocator);
    const side: f32 = @floatFromInt(clean.cols);
    // Straight-on, but with a strong brightness ramp plus perlin shading:
    // global thresholding fails here by construction.
    var photo = try photoSimulate(allocator, clean, .{
        .corners = .{
            .{ 8, 8 },
            .{ side + 8, 8 },
            .{ 8, side + 8 },
            .{ side + 8, side + 8 },
        },
        .out_rows = @intFromFloat(side + 16),
        .out_cols = @intFromFloat(side + 16),
        .ramp = 60,
        .perlin_amp = 25,
    });
    defer photo.deinit(allocator);
    try expectDecodes(allocator, photo, "UNEVEN LIGHTING");
}

test "decode under blur and noise" {
    const allocator = std.testing.allocator;
    var clean = try encoder.encodeImage(allocator, "BLUR AND NOISE", .{ .module_size = 6 });
    defer clean.deinit(allocator);
    const side: f32 = @floatFromInt(clean.cols);
    var photo = try photoSimulate(allocator, clean, .{
        .corners = .{
            .{ 8, 8 },
            .{ side + 8, 8 },
            .{ 8, side + 8 },
            .{ side + 8, side + 8 },
        },
        .out_rows = @intFromFloat(side + 16),
        .out_cols = @intFromFloat(side + 16),
        .sigma = 1.2,
        .noise = 10,
    });
    defer photo.deinit(allocator);
    try expectDecodes(allocator, photo, "BLUR AND NOISE");
}

test "decode combined photo distortions" {
    const allocator = std.testing.allocator;
    const versions = [_]?u8{ 1, 4, 10 }; // v1 exercises the parallelogram fallback
    for (versions) |version| {
        var clean = try encoder.encodeImage(allocator, "COMBINED PHOTO", .{
            .module_size = 8,
            .version = version,
        });
        defer clean.deinit(allocator);
        const side: f32 = @floatFromInt(clean.cols);
        // Version 1 has no alignment pattern, so the parallelogram fallback
        // cannot correct perspective; keep its keystone mild.
        const k: f32 = if (version == 1) 0.4 else 1;
        var photo = try photoSimulate(allocator, clean, .{
            .corners = .{
                .{ side * 0.12 * k, side * 0.08 * k },
                .{ side * (1 + 0.06 * k), side * 0.03 * k },
                .{ side * 0.04 * k, side * (1 + 0.04 * k) },
                .{ side * (1 + 0.12 * k), side * (1 + 0.10 * k) },
            },
            .out_rows = @intFromFloat(side * 1.22),
            .out_cols = @intFromFloat(side * 1.22),
            .ramp = 40,
            .perlin_amp = 15,
            .sigma = 0.8,
            .noise = 8,
        });
        defer photo.deinit(allocator);
        try expectDecodes(allocator, photo, "COMBINED PHOTO");
    }
}

test "decode version 40 at three pixels per module" {
    const allocator = std.testing.allocator;
    var clean = try encoder.encodeImage(allocator, "V40 SUBPIXEL BUDGET CANARY", .{
        .module_size = 3,
        .version = 40,
    });
    defer clean.deinit(allocator);
    const side: f32 = @floatFromInt(clean.cols);
    var photo = try photoSimulate(allocator, clean, .{
        .corners = .{
            .{ side * 0.04, side * 0.03 },
            .{ side * 1.02, side * 0.01 },
            .{ side * 0.02, side * 1.01 },
            .{ side * 1.04, side * 1.03 },
        },
        .out_rows = @intFromFloat(side * 1.08),
        .out_cols = @intFromFloat(side * 1.08),
    });
    defer photo.deinit(allocator);
    try expectDecodes(allocator, photo, "V40 SUBPIXEL BUDGET CANARY");
}

test "pickFinderTriple labels rotated centers" {
    // Centers of a symbol rotated 40 degrees; TL must be the right-angle
    // vertex and TR/BL must follow the cross-product convention.
    const cos = @cos(std.math.pi / 4.5);
    const sin = @sin(std.math.pi / 4.5);
    const place = struct {
        fn place(x: f32, y: f32, c: f32, s: f32) FinderPattern {
            return .{
                .center = .init(.{ 200 + c * x - s * y, 200 + s * x + c * y }),
                .module_size = 4,
                .hits = 1,
            };
        }
    }.place;
    const tl = place(-70, -70, cos, sin);
    const tr = place(70, -70, cos, sin);
    const bl = place(-70, 70, cos, sin);
    const triple = pickFinderTriple(&.{ tr, bl, tl }) orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(tl.center.y(), triple.top_left.center.y(), 0.01);
    try std.testing.expectApproxEqAbs(tl.center.x(), triple.top_left.center.x(), 0.01);
    try std.testing.expectApproxEqAbs(tr.center.y(), triple.top_right.center.y(), 0.01);
    try std.testing.expectApproxEqAbs(bl.center.x(), triple.bottom_left.center.x(), 0.01);
}

test "alignment pattern search on a rendered symbol" {
    const allocator = std.testing.allocator;
    const ms = 6;
    const qz = 4;
    var image = try encoder.encodeImage(allocator, "ALIGNMENT", .{
        .module_size = ms,
        .quiet_zone = qz,
        .version = 2,
    });
    defer image.deinit(allocator);
    // encodeImage emits 0/255, which is already binarized.
    const center = struct {
        fn center(module: f32) f32 {
            return (qz + module) * ms;
        }
    }.center;
    const triple: FinderTriple = .{
        .top_left = .{ .center = .init(.{ center(3.5), center(3.5) }), .module_size = ms, .hits = 1 },
        .top_right = .{ .center = .init(.{ center(25 - 3.5), center(3.5) }), .module_size = ms, .hits = 1 },
        .bottom_left = .{ .center = .init(.{ center(3.5), center(25 - 3.5) }), .module_size = ms, .hits = 1 },
    };
    var fourth_buf: [5]Fourth = undefined;
    const fourths = fourthCandidates(image, triple, 25, &fourth_buf);
    if (!fourths[0].is_alignment) return error.TestUnexpectedResult;
    const alignment = fourths[0];
    // Version 2 alignment center is at module (18, 18) = (dim-6.5, dim-6.5) - 0.5.
    try std.testing.expectApproxEqAbs(center(18.5), alignment.center.y(), @as(f32, ms) / 2);
    try std.testing.expectApproxEqAbs(center(18.5), alignment.center.x(), @as(f32, ms) / 2);
}

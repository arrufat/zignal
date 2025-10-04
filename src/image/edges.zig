const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Image = @import("../image.zig").Image;
const ShenCastan = @import("ShenCastan.zig");
const meta = @import("../meta.zig");
const as = meta.as;
const isScalar = meta.isScalar;
const convertColor = @import("../color.zig").convertColor;
const convolve = @import("convolution.zig").convolve;
const Integral = @import("integral.zig").Integral;

/// Sobel X gradient kernel (horizontal edges)
const sobel_x = [3][3]f32{
    .{ -1, 0, 1 },
    .{ -2, 0, 2 },
    .{ -1, 0, 1 },
};

/// Sobel Y gradient kernel (vertical edges)
const sobel_y = [3][3]f32{
    .{ -1, -2, -1 },
    .{ 0, 0, 0 },
    .{ 1, 2, 1 },
};

/// Edge detection operations.
/// Provides Sobel and Shen-Castan edge detection algorithms.
pub fn Edges(comptime T: type) type {
    return struct {
        /// Applies the Sobel filter to perform edge detection.
        /// The output is a grayscale image representing the magnitude of gradients at each pixel.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for temporary buffers.
        /// - `out`: Output image that will be filled with the Sobel magnitude image.
        pub fn sobel(self: Image(T), allocator: Allocator, out: Image(u8)) !void {
            // For now, use float path for all types to ensure correctness
            {
                // Convert input to grayscale float if needed
                var gray_float: Image(f32) = undefined;
                const needs_conversion = !isScalar(T) or @typeInfo(T) != .float;
                if (needs_conversion) {
                    gray_float = try Image(f32).init(allocator, self.rows, self.cols);
                    for (0..self.rows) |r| {
                        for (0..self.cols) |c| {
                            gray_float.at(r, c).* = as(f32, convertColor(u8, self.at(r, c).*));
                        }
                    }
                } else {
                    gray_float = self;
                }
                defer if (needs_conversion) gray_float.deinit(allocator);

                // Apply Sobel X and Y filters
                var grad_x = try Image(f32).initLike(allocator, gray_float);
                var grad_y = try Image(f32).initLike(allocator, gray_float);
                defer grad_x.deinit(allocator);
                defer grad_y.deinit(allocator);

                try convolve(f32, gray_float, allocator, sobel_x, .replicate, grad_x);
                try convolve(f32, gray_float, allocator, sobel_y, .replicate, grad_y);

                // Compute gradient magnitude
                for (0..self.rows) |r| {
                    for (0..self.cols) |c| {
                        const gx = grad_x.at(r, c).*;
                        const gy = grad_y.at(r, c).*;
                        const magnitude = @sqrt(gx * gx + gy * gy);
                        // Scale by 1/4 to match typical Sobel output range
                        // Max theoretical magnitude is ~1442, so /4 maps to ~360 max
                        const scaled = magnitude / 4.0;
                        out.at(r, c).* = @intFromFloat(@max(0, @min(255, scaled)));
                    }
                }
            }
        }

        /// Applies the Shen-Castan edge detection algorithm using the Infinite Symmetric
        /// Exponential Filter (ISEF). This algorithm provides superior edge localization
        /// and noise handling compared to traditional methods.
        ///
        /// Notes:
        /// - The Laplacian is approximated as (smoothed - original) for sign.
        /// - Border pixels (outermost row/column) are not processed for edge detection.
        /// - Thresholds apply to raw luminance differences (0..255 scale).
        pub fn shenCastan(
            self: Image(T),
            allocator: Allocator,
            opts: ShenCastan,
            out: Image(u8),
        ) !void {
            try opts.validate();

            // Convert to grayscale float for processing
            var gray_float = try Image(f32).init(allocator, self.rows, self.cols);
            defer gray_float.deinit(allocator);
            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    const gray_val = convertColor(u8, self.at(r, c).*);
                    gray_float.at(r, c).* = as(f32, gray_val);
                }
            }

            // Apply ISEF filter for smoothing
            var smoothed = try Image(f32).init(allocator, self.rows, self.cols);
            defer smoothed.deinit(allocator);
            try isefFilter2D(gray_float, opts.smooth, &smoothed, allocator);

            // Compute Laplacian approximation (smoothed - original)
            var laplacian = try Image(f32).init(allocator, self.rows, self.cols);
            defer laplacian.deinit(allocator);
            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    laplacian.at(r, c).* = smoothed.at(r, c).* - gray_float.at(r, c).*;
                }
            }

            // Generate Binary Laplacian Image (BLI)
            var bli = try Image(u8).init(allocator, self.rows, self.cols);
            defer bli.deinit(allocator);
            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    bli.at(r, c).* = if (laplacian.at(r, c).* >= 0) 1 else 0;
                }
            }

            // Find zero crossings according to thinning mode (for NMS, start from non-thinned mask)
            var edges = try Image(u8).init(allocator, self.rows, self.cols);
            defer edges.deinit(allocator);
            // For NMS, we start with non-thinned edges, otherwise use forward thinning
            try findZeroCrossings(bli, &edges, !opts.use_nms);

            // Compute gradient magnitudes at edge locations
            var gradients = try Image(f32).init(allocator, self.rows, self.cols);
            defer gradients.deinit(allocator);
            try computeAdaptiveGradients(gray_float, bli, edges, opts.window_size, &gradients, allocator);

            // Determine thresholds using ratio-based approach
            var t_low: f32 = 0;
            var t_high: f32 = 0;

            // Build histogram of gradient magnitudes at candidate edges
            var hist: [256]usize = @splat(0);
            var total: usize = 0;
            for (0..self.rows) |rr| {
                for (0..self.cols) |cc| {
                    if (edges.at(rr, cc).* == 0) continue;
                    var g = gradients.at(rr, cc).*;
                    if (g < 0) g = 0;
                    if (g > 255) g = 255;
                    const bin: usize = @intFromFloat(@round(g));
                    hist[bin] += 1;
                    total += 1;
                }
            }
            if (total == 0) {
                // No candidates -> output all zeros
                for (0..self.rows) |rr| {
                    for (0..self.cols) |cc| {
                        out.at(rr, cc).* = 0;
                    }
                }
                return;
            }
            const target: usize = @intFromFloat(@floor(@as(f32, @floatFromInt(total)) * opts.high_ratio));
            var cum: usize = 0;
            var idx: usize = 0;
            while (idx < 256 and cum < target) : (idx += 1) {
                cum += hist[idx];
            }
            // idx is the first bin where cum >= target
            t_high = @floatFromInt(@min(idx, 255));
            t_low = opts.low_rel * t_high;

            // Optional non-maximum suppression along gradient direction
            var edges_nms = Image(u8).empty;
            defer if (edges_nms.data.len > 0) edges_nms.deinit(allocator);
            const edges_for_thresh: Image(u8) = blk: {
                if (opts.use_nms) {
                    edges_nms = try Image(u8).init(allocator, self.rows, self.cols);
                    try nonMaxSuppressEdges(smoothed, gradients, edges, &edges_nms);
                    break :blk edges_nms;
                } else {
                    break :blk edges;
                }
            };

            if (!opts.hysteresis) {
                // Emit strong edges only
                for (0..self.rows) |r| {
                    for (0..self.cols) |c| {
                        const is_edge = edges_for_thresh.at(r, c).* > 0 and gradients.at(r, c).* >= t_high;
                        out.at(r, c).* = if (is_edge) 255 else 0;
                    }
                }
                return;
            }

            // Apply hysteresis thresholding with computed thresholds
            try applyHysteresis(edges_for_thresh, gradients, t_low, t_high, out, allocator);
        }

        /// Applies the Canny edge detection algorithm, a classic multi-stage edge detector.
        /// This algorithm produces thin, well-localized edges with good noise suppression.
        ///
        /// The Canny algorithm consists of five main steps:
        /// 1. Gaussian smoothing to reduce noise
        /// 2. Gradient computation using Sobel operators
        /// 3. Non-maximum suppression to thin edges
        /// 4. Double thresholding to classify strong and weak edges
        /// 5. Edge tracking by hysteresis to link edges
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for temporary buffers
        /// - `sigma`: Standard deviation for Gaussian blur (typical: 1.0-2.0)
        /// - `low_threshold`: Lower threshold for hysteresis (0-255)
        /// - `high_threshold`: Upper threshold for hysteresis (0-255)
        /// - `out`: Output edge map as binary image (0 or 255)
        ///
        /// Note: high_threshold should be 2-3x larger than low_threshold
        pub fn canny(
            self: Image(T),
            allocator: Allocator,
            sigma: f32,
            low_threshold: f32,
            high_threshold: f32,
            out: Image(u8),
        ) !void {
            // Check for non-finite values first to prevent runtime traps
            if (!std.math.isFinite(sigma) or !std.math.isFinite(low_threshold) or !std.math.isFinite(high_threshold)) {
                return error.InvalidParameter;
            }
            if (sigma < 0) return error.InvalidSigma;
            if (low_threshold < 0 or high_threshold < 0) return error.InvalidThreshold;
            if (low_threshold >= high_threshold) return error.InvalidThreshold;

            // Step 1: Convert to grayscale float for processing
            var gray_float = try Image(f32).init(allocator, self.rows, self.cols);
            defer gray_float.deinit(allocator);
            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    const gray_val = convertColor(u8, self.at(r, c).*);
                    gray_float.at(r, c).* = as(f32, gray_val);
                }
            }

            // Step 2: Apply Gaussian blur (or skip if sigma == 0)
            var blurred = try Image(f32).init(allocator, self.rows, self.cols);
            defer blurred.deinit(allocator);
            if (sigma == 0) {
                gray_float.copy(blurred);
            } else {
                try blurGaussian(gray_float, sigma, blurred, allocator);
            }

            // Step 3: Compute gradients using Sobel operators
            var grad_x = try Image(f32).initLike(allocator, blurred);
            var grad_y = try Image(f32).initLike(allocator, blurred);
            defer grad_x.deinit(allocator);
            defer grad_y.deinit(allocator);

            try convolve(f32, blurred, allocator, sobel_x, .replicate, grad_x);
            try convolve(f32, blurred, allocator, sobel_y, .replicate, grad_y);

            // Compute gradient magnitude
            var magnitude = try Image(f32).init(allocator, self.rows, self.cols);
            defer magnitude.deinit(allocator);
            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    const gx = grad_x.at(r, c).*;
                    const gy = grad_y.at(r, c).*;
                    magnitude.at(r, c).* = @sqrt(gx * gx + gy * gy);
                }
            }

            // Step 4: Non-maximum suppression
            var nms_edges = try Image(u8).init(allocator, self.rows, self.cols);
            defer nms_edges.deinit(allocator);
            try nonMaxSuppressionCanny(grad_x, grad_y, magnitude, &nms_edges);

            // Step 5: Double thresholding and hysteresis
            try applyHysteresis(nms_edges, magnitude, low_threshold, high_threshold, out, allocator);
        }
    };
}

// ============================================================================
// ISEF Filter Functions
// ============================================================================

/// Applies 1D ISEF recursive filter (forward + backward pass for symmetry)
fn isefFilter1D(data: []f32, b: f32, temp: []f32) void {
    const n = data.len;
    if (n == 0) return;

    const a = 1.0 - b;

    // Forward pass
    temp[0] = b * data[0];
    for (1..n) |i| {
        temp[i] = b * data[i] + a * temp[i - 1];
    }

    // Backward pass (for symmetric response)
    data[n - 1] = temp[n - 1];
    if (n > 1) {
        var i = n - 2;
        while (true) {
            data[i] = b * temp[i] + a * data[i + 1];
            if (i == 0) break;
            i -= 1;
        }
    }
}

/// Applies 2D ISEF filter by separable application in X and Y directions
fn isefFilter2D(src: Image(f32), b: f32, dst: *Image(f32), allocator: Allocator) !void {
    const rows = src.rows;
    const cols = src.cols;

    // Allocate temporary buffers
    var row_buffer = try allocator.alloc(f32, cols);
    defer allocator.free(row_buffer);
    const temp_buffer = try allocator.alloc(f32, cols);
    defer allocator.free(temp_buffer);

    // Apply ISEF horizontally (along rows)
    for (0..rows) |r| {
        // Copy row to buffer
        for (0..cols) |c| {
            row_buffer[c] = src.at(r, c).*;
        }
        // Apply 1D ISEF
        isefFilter1D(row_buffer, b, temp_buffer);
        // Copy back
        for (0..cols) |c| {
            dst.at(r, c).* = row_buffer[c];
        }
    }

    // Apply ISEF vertically (along columns)
    var col_buffer = try allocator.alloc(f32, rows);
    defer allocator.free(col_buffer);
    const temp_col_buffer = try allocator.alloc(f32, rows);
    defer allocator.free(temp_col_buffer);

    for (0..cols) |c| {
        // Copy column to buffer
        for (0..rows) |r| {
            col_buffer[r] = dst.at(r, c).*;
        }
        // Apply 1D ISEF
        isefFilter1D(col_buffer, b, temp_col_buffer);
        // Copy back
        for (0..rows) |r| {
            dst.at(r, c).* = col_buffer[r];
        }
    }
}

/// Finds zero crossings in the Binary Laplacian Image and produces an edge map.
/// If `use_forward` is true, marks a pixel when it differs from any forward neighbor (E, S, SE, SW)
/// which avoids double-marking and yields thinner edges. If false, marks any 4-neighbor transition
/// around the center (thicker edges, useful for debugging/visualization).
fn findZeroCrossings(bli: Image(u8), edges: *Image(u8), use_forward: bool) !void {
    const rows = bli.rows;
    const cols = bli.cols;

    // Initialize all to 0
    for (0..rows) |r| {
        for (0..cols) |c| {
            edges.at(r, c).* = 0;
        }
    }

    if (use_forward) {
        // Check transitions with forward neighbors to reduce double-marking
        for (0..rows) |r| {
            for (0..cols) |c| {
                const center = bli.at(r, c).*;
                var mark: bool = false;
                // East
                if (!mark and c + 1 < cols) mark = (center != bli.at(r, c + 1).*);
                // South
                if (!mark and r + 1 < rows) mark = (center != bli.at(r + 1, c).*);
                // South-East
                if (!mark and r + 1 < rows and c + 1 < cols) mark = (center != bli.at(r + 1, c + 1).*);
                // South-West
                if (!mark and r + 1 < rows and c > 0) mark = (center != bli.at(r + 1, c - 1).*);
                if (mark) edges.at(r, c).* = 255;
            }
        }
    } else {
        // Mark any 4-neighbor transition (used for NMS)
        if (rows >= 3 and cols >= 3) {
            for (1..rows - 1) |r| {
                for (1..cols - 1) |c| {
                    const center = bli.at(r, c).*;
                    const left = bli.at(r, c - 1).*;
                    const right = bli.at(r, c + 1).*;
                    const top = bli.at(r - 1, c).*;
                    const bottom = bli.at(r + 1, c).*;
                    if (center != left or center != right or center != top or center != bottom) {
                        edges.at(r, c).* = 255;
                    }
                }
            }
        } else {
            // Fallback for very small images: safe bounds
            for (0..rows) |r| {
                for (0..cols) |c| {
                    const center = bli.at(r, c).*;
                    var mark = false;
                    if (!mark and c > 0) mark = (center != bli.at(r, c - 1).*);
                    if (!mark and c + 1 < cols) mark = (center != bli.at(r, c + 1).*);
                    if (!mark and r > 0) mark = (center != bli.at(r - 1, c).*);
                    if (!mark and r + 1 < rows) mark = (center != bli.at(r + 1, c).*);
                    if (mark) edges.at(r, c).* = 255;
                }
            }
        }
    }
}

/// Computes adaptive gradient magnitudes using local window statistics with integral image acceleration
fn computeAdaptiveGradients(
    gray: Image(f32),
    bli: Image(u8),
    edges: Image(u8),
    window_size: usize,
    gradients: *Image(f32),
    allocator: Allocator,
) !void {
    const rows = gray.rows;
    const cols = gray.cols;
    const half_window = window_size / 2;

    // Initialize gradients to 0
    for (0..rows) |r| {
        for (0..cols) |c| {
            gradients.at(r, c).* = 0;
        }
    }

    // Build integral images for fast box sum computation
    const plane_size = rows * cols;

    // Integral image for grayscale values
    const integral_gray_buf = try allocator.alloc(f32, plane_size);
    defer allocator.free(integral_gray_buf);
    const integral_gray: Image(f32) = .{ .rows = rows, .cols = cols, .stride = cols, .data = integral_gray_buf };
    Integral(f32).plane(gray, integral_gray);

    // Integral image for BLI mask (where BLI == 1)
    const integral_mask_buf = try allocator.alloc(f32, plane_size);
    defer allocator.free(integral_mask_buf);
    const integral_mask: Image(f32) = .{ .rows = rows, .cols = cols, .stride = cols, .data = integral_mask_buf };
    Integral(u8).plane(bli, integral_mask);

    // Integral image for gray * mask (values where BLI == 1)
    const gray_masked_buf = try allocator.alloc(f32, plane_size);
    defer allocator.free(gray_masked_buf);
    for (0..plane_size) |i| {
        gray_masked_buf[i] = gray.data[i] * @as(f32, @floatFromInt(bli.data[i]));
    }
    const gray_masked: Image(f32) = .{ .rows = rows, .cols = cols, .stride = cols, .data = gray_masked_buf };
    const integral_gray_masked_buf = try allocator.alloc(f32, plane_size);
    defer allocator.free(integral_gray_masked_buf);
    const integral_gray_masked: Image(f32) = .{ .rows = rows, .cols = cols, .stride = cols, .data = integral_gray_masked_buf };
    Integral(f32).plane(gray_masked, integral_gray_masked);

    // Helper function to compute box sum from integral image
    const boxSum = struct {
        fn compute(img: Image(f32), r1: usize, r2: usize, c1: usize, c2: usize) f32 {
            // Box sum using integral image: sum = D - B - C + A
            // where A=(r1-1,c1-1), B=(r1-1,c2), C=(r2,c1-1), D=(r2,c2)
            var sum: f32 = img.at(r2, c2).*;
            if (r1 > 0) sum -= img.at(r1 - 1, c2).*;
            if (c1 > 0) sum -= img.at(r2, c1 - 1).*;
            if (r1 > 0 and c1 > 0) sum += img.at(r1 - 1, c1 - 1).*;
            return sum;
        }
    }.compute;

    // For each edge pixel, compute gradient using integral images (O(1) per pixel)
    for (0..rows) |r| {
        for (0..cols) |c| {
            if (edges.at(r, c).* == 0) continue;

            // Compute window bounds
            const r_start = if (r > half_window) r - half_window else 0;
            const r_end = @min(r + half_window, rows - 1);
            const c_start = if (c > half_window) c - half_window else 0;
            const c_end = @min(c + half_window, cols - 1);

            // Compute sums in O(1) using integral images
            const area = @as(f32, @floatFromInt((r_end - r_start + 1) * (c_end - c_start + 1)));
            const count1 = boxSum(integral_mask, r_start, r_end, c_start, c_end);
            const count0 = area - count1;

            if (count0 > 0 and count1 > 0) {
                const sum1 = boxSum(integral_gray_masked, r_start, r_end, c_start, c_end);
                const sum_total = boxSum(integral_gray, r_start, r_end, c_start, c_end);
                const sum0 = sum_total - sum1;

                const mean0 = sum0 / count0;
                const mean1 = sum1 / count1;
                gradients.at(r, c).* = @abs(mean1 - mean0);
            }
        }
    }
}

/// Applies hysteresis thresholding for final edge linking using BFS for O(N) performance.
/// Invariant: pixels are marked in `out` before being enqueued so each pixel is processed at most once.
fn applyHysteresis(
    edges: Image(u8),
    gradients: Image(f32),
    threshold_low: f32,
    threshold_high: f32,
    out: Image(u8),
    allocator: Allocator,
) !void {
    const rows = edges.rows;
    const cols = edges.cols;

    // Initialize output and visited tracking
    for (0..rows) |r| {
        for (0..cols) |c| {
            out.at(r, c).* = 0;
        }
    }

    // BFS queue for edge propagation (monotonic indices to avoid head/tail ambiguity)
    const max_queue_size = rows * cols;
    const QueueItem = struct { r: usize, c: usize };
    const queue_storage = try allocator.alloc(QueueItem, max_queue_size);
    defer allocator.free(queue_storage);

    var push_i: usize = 0;
    var pop_i: usize = 0;

    // Helper to enqueue (each pixel is enqueued at most once since we mark before enqueue)
    const enqueue = struct {
        fn push(q: []QueueItem, push_idx: *usize, r: usize, c: usize) void {
            assert(push_idx.* < q.len);
            q[push_idx.*] = .{ .r = r, .c = c };
            push_idx.* += 1;
        }
    }.push;

    // First pass: find and enqueue all strong edges
    for (0..rows) |r| {
        for (0..cols) |c| {
            if (edges.at(r, c).* > 0 and gradients.at(r, c).* >= threshold_high) {
                out.at(r, c).* = 255;
                enqueue(queue_storage, &push_i, r, c);
            }
        }
    }

    // BFS propagation: grow from strong edges to weak edges
    while (pop_i < push_i) {
        const current = queue_storage[pop_i];
        pop_i += 1;
        const r = current.r;
        const c = current.c;

        // Check 8-connected neighbors
        const r_start = if (r > 0) r - 1 else 0;
        const r_end = @min(r + 2, rows);
        const c_start = if (c > 0) c - 1 else 0;
        const c_end = @min(c + 2, cols);

        for (r_start..r_end) |nr| {
            for (c_start..c_end) |nc| {
                // Skip if same as current pixel
                if (nr == r and nc == c) continue;

                // Skip if already marked as edge
                if (out.at(nr, nc).* > 0) continue;

                // Check if it's a weak edge candidate
                if (edges.at(nr, nc).* > 0 and gradients.at(nr, nc).* >= threshold_low) {
                    // Mark as edge and add to queue for further propagation
                    out.at(nr, nc).* = 255;
                    enqueue(queue_storage, &push_i, nr, nc);
                }
            }
        }
    }
}

/// Non-maximum suppression along gradient direction to thin edges to single-pixel width.
/// - Uses central differences on the smoothed image to estimate local gradient direction.
/// - Quantizes orientation into 0°, 45°, 90°, 135° without atan2 using slope thresholds.
/// - Keeps a candidate pixel only if its adaptive magnitude is not less than its two
///   neighbors along the chosen direction.
fn nonMaxSuppressEdges(
    smoothed: Image(f32),
    gradients: Image(f32),
    edges_in: Image(u8),
    edges_out: *Image(u8),
) !void {
    const rows = edges_in.rows;
    const cols = edges_in.cols;

    // Initialize output to zero
    for (0..rows) |r| {
        for (0..cols) |c| {
            edges_out.at(r, c).* = 0;
        }
    }

    // Constants for direction quantization without atan2
    const K: f32 = 0.414213562; // tan(22.5°)

    if (rows < 3 or cols < 3) return; // Too small to compute central differences

    // Skip image border to avoid bounds checks; border remains zero
    for (1..rows - 1) |r| {
        for (1..cols - 1) |c| {
            if (edges_in.at(r, c).* == 0) continue;

            // Gradient via central differences on smoothed image
            const gx = 0.5 * (smoothed.at(r, c + 1).* - smoothed.at(r, c - 1).*);
            const gy = 0.5 * (smoothed.at(r + 1, c).* - smoothed.at(r - 1, c).*);

            const ax = @abs(gx);
            const ay = @abs(gy);

            // Choose neighbor offsets along quantized direction
            var dr1: isize = 0;
            var dc1: isize = 0;
            var dr2: isize = 0;
            var dc2: isize = 0;

            if (ay <= K * ax) {
                // 0°: compare left/right
                dr1 = 0;
                dc1 = -1;
                dr2 = 0;
                dc2 = 1;
            } else if (ax <= K * ay) {
                // 90°: compare up/down
                dr1 = -1;
                dc1 = 0;
                dr2 = 1;
                dc2 = 0;
            } else if (gx * gy > 0) {
                // 45°: up-right and down-left
                dr1 = -1;
                dc1 = 1;
                dr2 = 1;
                dc2 = -1;
            } else {
                // 135°: up-left and down-right
                dr1 = -1;
                dc1 = -1;
                dr2 = 1;
                dc2 = 1;
            }

            const m = gradients.at(r, c).*;
            const n1 = gradients.at(@intCast(@as(isize, @intCast(r)) + dr1), @intCast(@as(isize, @intCast(c)) + dc1)).*;
            const n2 = gradients.at(@intCast(@as(isize, @intCast(r)) + dr2), @intCast(@as(isize, @intCast(c)) + dc2)).*;

            if (m >= n1 and m >= n2) {
                edges_out.at(r, c).* = 255;
            }
        }
    }
}

// ============================================================================
// Canny Edge Detection Helper Functions
// ============================================================================

/// Applies Gaussian blur to an image for Canny edge detection preprocessing.
/// Uses separable convolution for efficiency.
fn blurGaussian(src: Image(f32), sigma: f32, dst: Image(f32), allocator: Allocator) !void {
    // Calculate kernel size (3 sigma on each side)
    const radius = @as(usize, @intFromFloat(@ceil(3.0 * sigma)));
    const kernel_size = 2 * radius + 1;

    // Generate 1D Gaussian kernel
    var kernel = try allocator.alloc(f32, kernel_size);
    defer allocator.free(kernel);

    var sum: f32 = 0;
    for (0..kernel_size) |i| {
        const x = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(radius));
        kernel[i] = @exp(-(x * x) / (2.0 * sigma * sigma));
        sum += kernel[i];
    }

    // Normalize kernel
    for (kernel) |*k| {
        k.* /= sum;
    }

    // Apply separable convolution
    const convolution_mod = @import("convolution.zig");
    try convolution_mod.convolveSeparable(f32, src, allocator, kernel, kernel, .replicate, dst);
}

/// Non-maximum suppression specifically for Canny edge detection.
/// Suppresses gradient magnitudes that are not local maxima along the gradient direction.
/// Marks pixels as 255 if they survive NMS, 0 otherwise.
fn nonMaxSuppressionCanny(
    grad_x: Image(f32),
    grad_y: Image(f32),
    magnitude: Image(f32),
    edges_out: *Image(u8),
) !void {
    const rows = magnitude.rows;
    const cols = magnitude.cols;

    // Initialize output to zero
    for (0..rows) |r| {
        for (0..cols) |c| {
            edges_out.at(r, c).* = 0;
        }
    }

    // Constants for direction quantization without atan2
    const K: f32 = 0.414213562; // tan(22.5°)

    if (rows < 3 or cols < 3) return; // Too small to compute central differences

    // Skip image border to avoid bounds checks; border remains zero
    for (1..rows - 1) |r| {
        for (1..cols - 1) |c| {
            const gx = grad_x.at(r, c).*;
            const gy = grad_y.at(r, c).*;

            const ax = @abs(gx);
            const ay = @abs(gy);

            // Choose neighbor offsets along quantized direction
            var dr1: isize = 0;
            var dc1: isize = 0;
            var dr2: isize = 0;
            var dc2: isize = 0;

            if (ay <= K * ax) {
                // 0°: compare left/right
                dr1 = 0;
                dc1 = -1;
                dr2 = 0;
                dc2 = 1;
            } else if (ax <= K * ay) {
                // 90°: compare up/down
                dr1 = -1;
                dc1 = 0;
                dr2 = 1;
                dc2 = 0;
            } else if (gx * gy > 0) {
                // 45°: up-right and down-left
                dr1 = -1;
                dc1 = 1;
                dr2 = 1;
                dc2 = -1;
            } else {
                // 135°: up-left and down-right
                dr1 = -1;
                dc1 = -1;
                dr2 = 1;
                dc2 = 1;
            }

            const m = magnitude.at(r, c).*;
            const n1 = magnitude.at(@intCast(@as(isize, @intCast(r)) + dr1), @intCast(@as(isize, @intCast(c)) + dc1)).*;
            const n2 = magnitude.at(@intCast(@as(isize, @intCast(r)) + dr2), @intCast(@as(isize, @intCast(c)) + dc2)).*;

            if (m >= n1 and m >= n2) {
                edges_out.at(r, c).* = 255;
            }
        }
    }
}

//! Configuration for the Shen–Castan (ISEF) edge detector.
//!
//! - Applies ISEF smoothing, detects zero‑crossings of (smoothed − original) sign,
//!   computes adaptive gradient magnitudes in a local window, then links edges via
//!   hysteresis (when enabled). By default, zero‑crossings are thinned for cleaner,
//!   single‑pixel edges.
//! - Thresholds operate on raw luminance differences in the 0–255 range.
//! - The outermost border pixels are not considered for zero‑crossings.

const ShenCastan = @This();

// Core parameters
/// ISEF smoothing factor `b` (0 < b < 1).
/// Higher values preserve more detail (less smoothing). Typical range: 0.7–0.9.
smooth: f32 = 0.9,

/// Odd window size used to compute local mean differences across the zero‑crossing.
/// Must be ≥ 3. Larger windows (e.g. 9–11) are more robust to noise.
windowSize: usize = 7,

/// Thresholding mode: percentile‑based (ratio, default) or explicit absolute values.
thresholds: Thresholds = .{ .ratio = .{} },

/// When true (default), performs BFS hysteresis to link weak edges connected to
/// strong ones. When false, only strong edges are returned.
hysteresis: bool = true,

/// Zero‑crossing thinning strategy.
/// `.forward` marks only forward neighbor transitions (E/S/SE/SW) for thinner edges.
/// `.none` marks any 4‑neighbor transition (thicker, useful for debugging).
/// `.nms` applies non‑maximum suppression along local gradient direction.
thin: Thin = .forward,

/// Available thinning strategies for zero‑crossing marking.
pub const Thin = enum {
    /// Thicker map: mark any 4‑neighbor transition around the center.
    none,
    /// Thinner map: mark only forward neighbor transitions (E/S/SE/SW).
    forward,
    /// Non‑maximum suppression along local gradient direction for true single‑pixel edges.
    nms,
};

/// Percentile‑based threshold selection.
/// `high` is set to the gradient magnitude at `highRatio` quantile across edge
/// candidates; `low` is derived as `lowRel * high`.
pub const Ratio = struct {
    /// Quantile in (0, 1) used to select `high` (e.g. 0.99 → top 1% are strong).
    highRatio: f32 = 0.99,
    /// Relative factor in (0, 1) so that `low = lowRel * high`.
    lowRel: f32 = 0.5,
};

/// Explicit absolute thresholds (0–255). Must satisfy `0 < low < high`.
pub const Explicit = struct {
    /// Lower hysteresis threshold.
    low: f32,
    /// Upper hysteresis threshold.
    high: f32,
};

/// Selects thresholding strategy: percentile‑based (`ratio`) or explicit values.
pub const Thresholds = union(enum) {
    /// Percentile‑based thresholds using image content.
    ratio: Ratio,
    /// Explicit absolute thresholds in gradient units.
    explicit: Explicit,
};

/// Validates option values and returns a descriptive error on invalid input:
/// - `InvalidBParameter`: if `smooth` is not in (0, 1)
/// - `WindowSizeMustBeOdd`: if `windowSize` is even
/// - `WindowSizeTooSmall`: if `windowSize` < 3
/// - `InvalidThreshold`: for invalid ratio/explicit ranges
/// - `InvalidThresholdOrder`: if `explicit.low >= explicit.high`
pub fn validate(self: ShenCastan) !void {
    if (!(self.smooth > 0 and self.smooth < 1)) return error.InvalidBParameter;
    if (self.windowSize % 2 == 0) return error.WindowSizeMustBeOdd;
    if (self.windowSize < 3) return error.WindowSizeTooSmall;
    switch (self.thresholds) {
        .ratio => |r| {
            if (!(r.highRatio > 0 and r.highRatio < 1)) return error.InvalidThreshold;
            if (!(r.lowRel > 0 and r.lowRel < 1)) return error.InvalidThreshold;
        },
        .explicit => |e| {
            if (!(e.low > 0 and e.high > 0)) return error.InvalidThreshold;
            if (e.low >= e.high) return error.InvalidThresholdOrder;
        },
    }
}

/// Sensible defaults (auto thresholds, forward thinning, hysteresis on).
pub const default: ShenCastan = .{};

/// Preset tuned for low‑noise images (retain detail, fewer strong edges by percentile).
pub const low_noise: ShenCastan = .{
    .smooth = 0.9,
    .windowSize = 7,
    .thresholds = .{ .ratio = .{ .highRatio = 0.995, .lowRel = 0.5 } },
};

/// Preset tuned for high‑noise images (more smoothing, larger window).
pub const high_noise: ShenCastan = .{
    .smooth = 0.8,
    .windowSize = 11,
    .thresholds = .{ .ratio = .{ .highRatio = 0.99, .lowRel = 0.5 } },
};

/// Preset for higher sensitivity (more edges): lower percentile and lower relative low.
pub const sensitive: ShenCastan = .{
    .smooth = 0.9,
    .windowSize = 7,
    .thresholds = .{ .ratio = .{ .highRatio = 0.97, .lowRel = 0.4 } },
};

/// Preset to visualize thicker transitions (debug/visualization): disables thinning.
pub const thick: ShenCastan = .{ .thin = .none };

/// Preset to enable non‑maximum suppression thinning for single‑pixel edges.
pub const nms_thin: ShenCastan = .{ .thin = .nms };

/// Preset to return only strong edges (no linking).
pub const strong_only: ShenCastan = .{ .hysteresis = false };

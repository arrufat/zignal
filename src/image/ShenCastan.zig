//! Configuration for the Shen–Castan (ISEF) edge detector.
//!
//! Applies ISEF smoothing, detects zero‑crossings, computes adaptive gradient
//! magnitudes in a local window, then links edges via hysteresis.
//! Uses percentile-based thresholds that automatically adapt to image content.

const ShenCastan = @This();

/// ISEF smoothing factor (0 < smooth < 1).
/// Higher values preserve more detail (less smoothing). Typical range: 0.7–0.9.
smooth: f32 = 0.9,

/// Odd window size for computing local gradient statistics.
/// Must be ≥ 3. Larger windows (e.g. 9–11) are more robust to noise.
window_size: usize = 7,

/// Percentile for high threshold selection (0 < high_ratio < 1).
/// E.g. 0.99 means only the top 1% of gradients are considered strong edges.
high_ratio: f32 = 0.99,

/// Low threshold as a fraction of high threshold (0 < low_rel < 1).
/// E.g. 0.5 means low threshold = 0.5 * high threshold.
low_rel: f32 = 0.5,

/// Enable hysteresis edge linking.
/// When true, weak edges connected to strong edges are preserved.
hysteresis: bool = true,

/// Use non-maximum suppression for single-pixel edges.
/// When false, uses forward-neighbor thinning (faster).
/// When true, uses NMS for cleaner single-pixel edges (slower).
use_nms: bool = false,

/// Validates option values and returns descriptive errors:
/// - `InvalidBParameter`: if `smooth` is not in (0, 1)
/// - `WindowSizeMustBeOdd`: if `window_size` is even
/// - `WindowSizeTooSmall`: if `window_size` < 3
/// - `InvalidThreshold`: if thresholds are out of range
pub fn validate(self: ShenCastan) !void {
    if (!(self.smooth > 0 and self.smooth < 1)) return error.InvalidBParameter;
    if (self.window_size % 2 == 0) return error.WindowSizeMustBeOdd;
    if (self.window_size < 3) return error.WindowSizeTooSmall;
    if (!(self.high_ratio > 0 and self.high_ratio < 1)) return error.InvalidThreshold;
    if (!(self.low_rel > 0 and self.low_rel < 1)) return error.InvalidThreshold;
}

// ============================================================================
// Preset Configurations
// ============================================================================

/// Default configuration with balanced settings.
/// Good starting point for most images.
pub const default = ShenCastan{};

/// Optimized for low-noise, high-quality images.
/// Less smoothing to preserve fine details, stricter edge thresholds.
pub const low_noise = ShenCastan{
    .smooth = 0.95,
    .high_ratio = 0.98,
};

/// Optimized for noisy images.
/// More aggressive smoothing with larger window to suppress noise.
pub const high_noise = ShenCastan{
    .smooth = 0.7,
    .window_size = 11,
};

/// Heavy smoothing for very noisy or low-quality images.
/// Uses strong ISEF smoothing with moderate thresholds to suppress artifacts.
pub const heavy_smooth = ShenCastan{
    .smooth = 0.5,
    .window_size = 9,
    .high_ratio = 0.95,
};

/// Higher sensitivity configuration.
/// Detects more edges by using lower thresholds.
pub const sensitive = ShenCastan{
    .high_ratio = 0.97,
    .low_rel = 0.4,
};

/// Produces single-pixel wide edges using non-maximum suppression.
/// Slower but gives cleaner, thinner edge lines.
pub const thin = ShenCastan{
    .use_nms = true,
};

/// Detects only strong edges without hysteresis linking.
/// Useful when you want only the most prominent edges.
pub const strong_only = ShenCastan{
    .hysteresis = false,
};

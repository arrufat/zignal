const zignal = @import("zignal");

const stub_metadata = @import("stub_metadata.zig");

// Documentation for the Interpolation enum (used at runtime and for stub generation)
pub const interpolation_doc =
    \\Interpolation methods for image resizing.
    \\
    \\Performance and quality comparison:
    \\
    \\| Method            | Quality | Speed | Best Use Case       | Overshoot |
    \\|-------------------|---------|-------|---------------------|-----------|
    \\| NEAREST_NEIGHBOR  | ★☆☆☆☆   | ★★★★★ | Pixel art, masks    | No        |
    \\| BILINEAR          | ★★☆☆☆   | ★★★★☆ | Real-time, preview  | No        |
    \\| BICUBIC           | ★★★☆☆   | ★★★☆☆ | General purpose     | Yes       |
    \\| CATMULL_ROM       | ★★★★☆   | ★★★☆☆ | Natural images      | No        |
    \\| MITCHELL          | ★★★★☆   | ★★☆☆☆ | Balanced quality    | Yes       |
    \\| LANCZOS           | ★★★★★   | ★☆☆☆☆ | High-quality resize | Yes       |
    \\
    \\Note: "Overshoot" means the filter can create values outside the input range,
    \\which can cause ringing artifacts but may also enhance sharpness.
;

// Per-value documentation for stub generation
pub const interpolation_values = [_]stub_metadata.EnumValueDoc{
    .{ .name = "NEAREST_NEIGHBOR", .doc = "Fastest, pixelated, good for pixel art" },
    .{ .name = "BILINEAR", .doc = "Fast, smooth, good for real-time" },
    .{ .name = "BICUBIC", .doc = "Balanced quality/speed, general purpose" },
    .{ .name = "CATMULL_ROM", .doc = "Sharp, good for natural images" },
    .{ .name = "MITCHELL", .doc = "High quality, reduces ringing" },
    .{ .name = "LANCZOS", .doc = "Highest quality, slowest, for final output" },
};

// No runtime PyTypeObject; Interpolation is exposed via Python's IntEnum registration

// ============================================================================
// INTERPOLATION METHOD STUB GENERATION METADATA
// ============================================================================

pub const interpolation_enum_info = stub_metadata.EnumInfo{
    .name = "Interpolation",
    .doc = "Interpolation methods for image resizing",
    .zig_type = zignal.Interpolation,
};

//! Blending enum for color blending operations

const zignal = @import("zignal");
const py_utils = @import("py_utils.zig");
const c = py_utils.c;
const stub_metadata = @import("stub_metadata.zig");
const enum_utils = @import("enum_utils.zig");

// Documentation for the Blending enum (used at runtime and for stub generation)
pub const blending_doc =
    \\Blending modes for color composition.
    \\
    \\## Overview
    \\These modes determine how colors are combined when blending. Each mode produces
    \\different visual effects useful for various image compositing operations.
    \\
    \\## Blend Modes
    \\
    \\| Mode        | Description                                            | Best Use Case     |
    \\|-------------|--------------------------------------------------------|-------------------|
    \\| NORMAL      | Standard alpha blending with transparency              | Layering images   |
    \\| MULTIPLY    | Darkens by multiplying colors (white has no effect)    | Shadows, darkening|
    \\| SCREEN      | Lightens by inverting, multiplying, then inverting     | Highlights, glow  |
    \\| OVERLAY     | Combines multiply and screen based on base color       | Contrast enhance  |
    \\| SOFT_LIGHT  | Gentle contrast adjustment                             | Subtle lighting   |
    \\| HARD_LIGHT  | Like overlay but uses overlay color to determine blend | Strong contrast   |
    \\| COLOR_DODGE | Brightens base color based on overlay                  | Bright highlights |
    \\| COLOR_BURN  | Darkens base color based on overlay                    | Deep shadows      |
    \\| DARKEN      | Selects darker color per channel                       | Remove white      |
    \\| LIGHTEN     | Selects lighter color per channel                      | Remove black      |
    \\| DIFFERENCE  | Subtracts darker from lighter color                    | Invert/compare    |
    \\| EXCLUSION   | Similar to difference but with lower contrast          | Soft inversion    |
    \\
    \\## Examples
    \\```python
    \\base = zignal.Rgb(100, 100, 100)
    \\overlay = zignal.Rgba(200, 50, 150, 128)
    \\
    \\# Apply different blend modes
    \\normal = base.blend(overlay, zignal.Blending.NORMAL)
    \\multiply = base.blend(overlay, zignal.Blending.MULTIPLY)
    \\screen = base.blend(overlay, zignal.Blending.SCREEN)
    \\```
    \\
    \\## Notes
    \\- All blend modes respect alpha channel for proper compositing
    \\- Result color type matches the base color type
    \\- Overlay must be RGBA or convertible to RGBA
;

// Per-value documentation for stub generation
pub const blending_values = [_]stub_metadata.EnumValueDoc{
    .{ .name = "NORMAL", .doc = "Standard alpha blending with transparency" },
    .{ .name = "MULTIPLY", .doc = "Darkens by multiplying colors" },
    .{ .name = "SCREEN", .doc = "Lightens by inverting, multiplying, inverting" },
    .{ .name = "OVERLAY", .doc = "Combines multiply and screen for contrast" },
    .{ .name = "SOFT_LIGHT", .doc = "Gentle contrast adjustment" },
    .{ .name = "HARD_LIGHT", .doc = "Strong contrast, like overlay but reversed" },
    .{ .name = "COLOR_DODGE", .doc = "Brightens base color, creates glow effects" },
    .{ .name = "COLOR_BURN", .doc = "Darkens base color, creates deep shadows" },
    .{ .name = "DARKEN", .doc = "Selects darker color per channel" },
    .{ .name = "LIGHTEN", .doc = "Selects lighter color per channel" },
    .{ .name = "DIFFERENCE", .doc = "Subtracts colors for inversion effect" },
    .{ .name = "EXCLUSION", .doc = "Like difference but with lower contrast" },
};

// No conversion wrapper; use enum_utils.pyToEnum(zignal.Blending, obj) where needed

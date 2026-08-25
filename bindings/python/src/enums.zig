//! Every enum the module exports. `main.zig` registers them at import and
//! `generate_stubs.zig` writes their stub classes and re-exports from the same
//! table, so an enum cannot exist in one and be missing from the other.

const zignal = @import("zignal");

const stub_metadata = @import("stub_metadata.zig");
const blending = @import("blending.zig");
const border_mode = @import("border_mode.zig");
const canvas = @import("canvas.zig");
const image = @import("image.zig");
const interpolation = @import("interpolation.zig");
const optimization = @import("optimization.zig");
const qrcode = @import("qrcode.zig");

/// The Python class is named after the Zig type (`zignal.meta.getSimpleTypeName`).
pub const Entry = struct {
    type: type,
    doc: []const u8,
    values: []const stub_metadata.EnumValueDoc,
};

pub const registry = [_]Entry{
    .{ .type = zignal.DrawMode, .doc = canvas.draw_mode_doc, .values = &canvas.draw_mode_values },
    .{ .type = zignal.TextAlign, .doc = canvas.text_align_doc, .values = &canvas.text_align_values },
    .{ .type = zignal.VerticalAlign, .doc = canvas.vertical_align_doc, .values = &canvas.vertical_align_values },
    .{ .type = zignal.Blending, .doc = blending.blending_doc, .values = &blending.blending_values },
    .{ .type = zignal.Interpolation, .doc = interpolation.interpolation_doc, .values = &interpolation.interpolation_values },
    .{ .type = zignal.BorderMode, .doc = border_mode.border_mode_doc, .values = &border_mode.border_mode_values },
    .{ .type = zignal.FloodFillOptions.ThresholdMode, .doc = image.threshold_mode_doc, .values = &image.threshold_mode_values },
    .{ .type = zignal.optimization.OptimizationPolicy, .doc = optimization.optimization_policy_doc, .values = &optimization.optimization_policy_values },
    .{ .type = zignal.qrcode.EcLevel, .doc = qrcode.ec_level_doc, .values = &qrcode.ec_level_values },
};

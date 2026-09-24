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

/// The Python class is named after the Zig type (`zignal.meta.getSimpleTypeName`) unless
/// `name` overrides it.
pub const Entry = struct {
    type: type,
    name: ?[]const u8 = null,
    doc: []const u8,
    values: []const stub_metadata.EnumValueDoc,
};

pub const registry = [_]Entry{
    .{ .type = zignal.canvas.DrawMode, .doc = canvas.draw_mode_doc, .values = &canvas.draw_mode_values },
    .{ .type = zignal.font.TextAlign, .doc = canvas.text_align_doc, .values = &canvas.text_align_values },
    .{ .type = zignal.font.VerticalAlign, .doc = canvas.vertical_align_doc, .values = &canvas.vertical_align_values },
    .{ .type = zignal.Blending, .doc = blending.blending_doc, .values = &blending.blending_values },
    .{ .type = zignal.image.Interpolation, .doc = interpolation.interpolation_doc, .values = &interpolation.interpolation_values },
    .{ .type = zignal.image.BorderMode, .doc = border_mode.border_mode_doc, .values = &border_mode.border_mode_values },
    .{ .type = zignal.image.FloodFillOptions.ThresholdMode, .doc = image.threshold_mode_doc, .values = &image.threshold_mode_values },
    .{ .type = zignal.image.GaussianMethod, .doc = image.gaussian_method_doc, .values = &image.gaussian_method_values },
    .{ .type = zignal.optimization.Policy, .name = "OptimizationPolicy", .doc = optimization.optimization_policy_doc, .values = &optimization.optimization_policy_values },
    .{ .type = zignal.qrcode.EcLevel, .doc = qrcode.ec_level_doc, .values = &qrcode.ec_level_values },
};

/// The Python name of `E`: its registry override, else the Zig type's simple name.
pub fn pythonName(comptime E: type) []const u8 {
    inline for (registry) |entry| {
        if (entry.type == E) if (entry.name) |name| return name;
    }
    return zignal.meta.getSimpleTypeName(E);
}

//! Border mode enum documentation for Python bindings

const stub_metadata = @import("stub_metadata.zig");

pub const border_mode_doc =
    \\Border handling strategies used by convolution and order-statistic filters.
    \\
    \\- `ZERO`: Pad with zeros outside the source image.
    \\- `REPLICATE`: Repeat the nearest edge pixel.
    \\- `MIRROR`: Reflect pixels at the border (default).
    \\- `WRAP`: Wrap around to the opposite edge.
;

pub const border_mode_values = [_]stub_metadata.EnumValueDoc{
    .{ .name = "ZERO", .doc = "Pad with zeros outside the image" },
    .{ .name = "REPLICATE", .doc = "Repeat the nearest edge pixel" },
    .{ .name = "MIRROR", .doc = "Reflect pixels across the border" },
    .{ .name = "WRAP", .doc = "Wrap around to the opposite edge" },
};

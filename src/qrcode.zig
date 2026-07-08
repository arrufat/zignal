//! QR code encoding and decoding (ISO/IEC 18004).
//!
//! Supports all 40 versions, the four error correction levels, and the
//! numeric, alphanumeric, and byte modes. The decoder handles photographs
//! (perspective distortion, uneven lighting, moderate blur) as well as clean
//! generated images, in any of the four rotations, mirrored or not, down to
//! roughly 2 pixels per module.

pub const EcLevel = @import("qrcode/tables.zig").EcLevel;
pub const BitMatrix = @import("qrcode/matrix.zig").BitMatrix;

pub const EncodeOptions = @import("qrcode/encoder.zig").EncodeOptions;
pub const encode = @import("qrcode/encoder.zig").encode;
pub const encodeImage = @import("qrcode/encoder.zig").encodeImage;
pub const toImage = @import("qrcode/encoder.zig").toImage;

pub const DecodeResult = @import("qrcode/decoder.zig").DecodeResult;
pub const decode = @import("qrcode/detector.zig").decode;
pub const decodeModules = @import("qrcode/decoder.zig").decodeModules;

test {
    _ = @import("qrcode/galois.zig");
    _ = @import("qrcode/reed_solomon.zig");
    _ = @import("qrcode/tables.zig");
    _ = @import("qrcode/segment.zig");
    _ = @import("qrcode/matrix.zig");
    _ = @import("qrcode/encoder.zig");
    _ = @import("qrcode/decoder.zig");
    _ = @import("qrcode/detector.zig");
}

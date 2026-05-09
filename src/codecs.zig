//! Image codec aggregator. Re-exports the four codec modules so that
//! `src/root.zig` and other in-tree consumers have a single import point,
//! and so the build's per-format tests share `src/` as their module root
//! (codec internals reach `../color.zig` etc., which would fall outside
//! the module path if each codec file were a test root on its own).

pub const bmp = @import("codecs/bmp.zig");
pub const gif = @import("codecs/gif.zig");
pub const jpeg = @import("codecs/jpeg.zig");
pub const png = @import("codecs/png.zig");

test {
    _ = bmp;
    _ = gif;
    _ = jpeg;
    _ = png;
}

//! Terminal graphics: capability detection plus the sixel, kitty, and iTerm2
//! image-encoding protocols.
//!
//! Detection helpers are re-exported flat (`terminal.isSixelSupported`, ...),
//! while each protocol encoder lives under its own namespace
//! (`terminal.sixel.fromImage`, `terminal.kitty.fromImage`, ...).

const detect = @import("terminal/detect.zig");

// Capability detection (see terminal/detect.zig)
pub const DetectionOptions = detect.DetectionOptions;
pub const isStdoutTty = detect.isStdoutTty;
pub const isSixelSupported = detect.isSixelSupported;
pub const isKittySupported = detect.isKittySupported;
pub const isIterm2Supported = detect.isIterm2Supported;
pub const aspectScale = detect.aspectScale;

// Image-encoding protocols
pub const sixel = @import("terminal/sixel.zig");
pub const kitty = @import("terminal/kitty.zig");
pub const iterm2 = @import("terminal/iterm2.zig");

test {
    // Aggregate the submodule tests so `zig build test` (which roots this
    // module at the barrel) exercises detection and every protocol encoder.
    _ = detect;
    _ = sixel;
    _ = kitty;
    _ = iterm2;
}

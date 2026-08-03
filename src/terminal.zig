//! Terminal graphics: capability detection plus the sixel, kitty, and iTerm2
//! image-encoding protocols.
//!
//! Each protocol encoder lives under its own namespace and exposes its
//! canonical capability probe (`terminal.sixel.fromImage`,
//! `terminal.kitty.isSupported`, ...).

const detect = @import("terminal/detect.zig");

// Shared helpers (see terminal/detect.zig)
pub const isStdoutTty = detect.isStdoutTty;
pub const aspectScale = detect.aspectScale;
pub const isIdentityScale = detect.isIdentityScale;

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

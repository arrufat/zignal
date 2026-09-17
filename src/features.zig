//! Feature detection, description, and matching.
//!
//! Provides FAST corner detection, ORB (Oriented FAST and Rotated BRIEF) feature extraction,
//! brute-force Hamming distance matching, and contour tracing.

pub const KeyPoint = @import("features/KeyPoint.zig");
pub const BinaryDescriptor = @import("features/BinaryDescriptor.zig");

pub const Fast = @import("features/Fast.zig");
pub const Orb = @import("features/orb.zig");
pub const Tracer = @import("features/Tracer.zig").Tracer;

pub const BruteForceMatcher = @import("features/matcher.zig").BruteForceMatcher;
pub const Match = @import("features/matcher.zig").Match;
pub const MatchStats = @import("features/matcher.zig").MatchStats;

test {
    // Run all feature module tests
    _ = @import("features/KeyPoint.zig");
    _ = @import("features/BinaryDescriptor.zig");
    _ = @import("features/Fast.zig");
    _ = @import("features/orb.zig");
    _ = @import("features/matcher.zig");
    _ = @import("features/Tracer.zig");
    _ = @import("features/test_orb_integration.zig");
}

//! Feature detection and description module for Zignal
//!
//! This module provides ORB (Oriented FAST and Rotated BRIEF) feature detection,
//! which is a fast, patent-free alternative to SIFT and SURF suitable for
//! real-time applications.

// Core data structures
pub const KeyPoint = @import("features/KeyPoint.zig");
pub const BinaryDescriptor = @import("features/BinaryDescriptor.zig");

// Feature detection
pub const Fast = @import("features/Fast.zig");
pub const Orb = @import("features/Orb.zig");

// Feature matching
pub const BruteForceMatcher = @import("features/matcher.zig").BruteForceMatcher;
pub const Match = @import("features/matcher.zig").Match;
pub const MatchStats = @import("features/matcher.zig").MatchStats;

test {
    // Run all feature module tests
    _ = @import("features/KeyPoint.zig");
    _ = @import("features/BinaryDescriptor.zig");
    _ = @import("features/Fast.zig");
    _ = @import("features/Orb.zig");
    _ = @import("features/matcher.zig");
}

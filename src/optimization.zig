//! Optimization algorithms.
//!
//! - **Assignment problem**: Hungarian (Kuhn-Munkres) solver — `solveAssignmentProblem`.
//! - **Global optimization**: derivative-free, bound-constrained MaxLIPO+TR — `GlobalOptimizer`,
//!   `findGlobalOptimum`.

const assignment = @import("optimization/assignment.zig");
const global_search = @import("optimization/global_search.zig");

/// Whether an optimizer should minimize or maximize the objective. Shared by every solver here.
pub const OptimizationPolicy = enum { min, max };

// Assignment problem
pub const Assignment = assignment.Assignment;
pub const solveAssignmentProblem = assignment.solveAssignmentProblem;

// Global optimization (MaxLIPO + Trust Region)
pub const GlobalOptimizer = global_search.GlobalOptimizer;
pub const GlobalError = global_search.GlobalError;
pub const findGlobalOptimum = global_search.findGlobalOptimum;

test {
    _ = @import("optimization/assignment.zig");
    _ = @import("optimization/trust_region.zig");
    _ = @import("optimization/lipschitz.zig");
    _ = @import("optimization/global_search.zig");
}

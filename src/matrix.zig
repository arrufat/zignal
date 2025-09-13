//! This module provides a generic, fixed-size Matrix struct for floating-point types
//! and a collection of common linear algebra operations such as addition, multiplication,
//! dot product, transpose, norm computation, determinant, and inverse (for small matrices).

// Re-export all matrix functionality
pub const SMatrix = @import("matrix/SMatrix.zig").SMatrix;
pub const Matrix = @import("matrix/Matrix.zig").Matrix;

test {
    _ = @import("matrix/SMatrix.zig");
    _ = @import("matrix/Matrix.zig");
    _ = @import("matrix/svd.zig");
    _ = @import("matrix/test_ops_basic.zig");
    _ = @import("matrix/test_ops_gemm.zig");
    _ = @import("matrix/test_ops_determinant.zig");
    _ = @import("matrix/test_ops_inverse.zig");
    _ = @import("matrix/test_ops_advanced.zig");
    _ = @import("matrix/test_ops_decomposition.zig");
    _ = @import("matrix/test_svd_comparison.zig");
}

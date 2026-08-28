//! Dynamic (`Matrix`) and compile-time sized (`SMatrix`) matrices with the usual linear
//! algebra: elementwise ops, products, norms, LU/QR/Cholesky/SVD/symmetric-eigen
//! decompositions, solve, inverse and pseudo-inverse.

// Re-export all matrix functionality
pub const SMatrix = @import("matrix/SMatrix.zig").SMatrix;
pub const Matrix = @import("matrix/Matrix.zig").Matrix;
pub const Chain = @import("matrix/Chain.zig").Chain;
pub const MatrixError = @import("matrix/Matrix.zig").MatrixError;
pub const cholesky = @import("matrix/Matrix.zig").cholesky;

test {
    _ = @import("matrix/SMatrix.zig");
    _ = @import("matrix/Matrix.zig");
    _ = @import("matrix/Chain.zig");
    _ = @import("matrix/svd.zig");
    _ = @import("matrix/eigen.zig");
    _ = @import("matrix/formatting.zig");
    _ = @import("matrix/test_ops_basic.zig");
    _ = @import("matrix/test_ops_gemm.zig");
    _ = @import("matrix/test_ops_determinant.zig");
    _ = @import("matrix/test_ops_inverse.zig");
    _ = @import("matrix/test_ops_advanced.zig");
    _ = @import("matrix/test_ops_decomposition.zig");
    _ = @import("matrix/test_svd_comparison.zig");
}

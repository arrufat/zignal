//! This module provides a generic, fixed-size Matrix struct for floating-point types
//! and a collection of common linear algebra operations such as addition, multiplication,
//! dot product, transpose, norm computation, determinant, and inverse (for small matrices).

// Re-export all matrix functionality
pub const SMatrix = @import("matrix/SMatrix.zig").SMatrix;
pub const Matrix = @import("matrix/Matrix.zig").Matrix;
pub const OpsBuilder = @import("matrix/OpsBuilder.zig").OpsBuilder;

//! Dynamic matrix with runtime dimensions

const std = @import("std");
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const formatting = @import("formatting.zig");
const SMatrix = @import("SMatrix.zig").SMatrix;
const svd_module = @import("svd.zig");
pub const SvdMode = svd_module.SvdMode;
pub const SvdOptions = svd_module.SvdOptions;
pub const SvdResult = svd_module.SvdResult;

/// Matrix with runtime dimensions using flat array storage
pub fn Matrix(comptime T: type) type {
    return struct {
        const Self = @This();

        items: []T,
        rows: usize,
        cols: usize,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, rows: usize, cols: usize) !Self {
            const data = try allocator.alloc(T, rows * cols);
            return Self{
                .items = data,
                .rows = rows,
                .cols = cols,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.items);
        }

        /// Returns the rows and columns as a struct.
        pub fn shape(self: Self) struct { usize, usize } {
            return .{ self.rows, self.cols };
        }

        /// Retrieves the element at position row, col in the matrix.
        pub inline fn at(self: Self, row: usize, col: usize) *T {
            assert(row < self.rows);
            assert(col < self.cols);
            return &self.items[row * self.cols + col];
        }

        /// Returns a matrix with all elements set to value.
        pub fn initAll(allocator: std.mem.Allocator, rows: usize, cols: usize, value: T) !Self {
            const result = try init(allocator, rows, cols);
            @memset(result.items, value);
            return result;
        }

        /// Returns an identity-like matrix.
        pub fn identity(allocator: std.mem.Allocator, rows: usize, cols: usize) !Self {
            var result = try initAll(allocator, rows, cols, 0);
            for (0..@min(rows, cols)) |i| {
                result.at(i, i).* = 1;
            }
            return result;
        }

        /// Returns a matrix filled with random floating-point numbers.
        pub fn random(allocator: std.mem.Allocator, rows: usize, cols: usize, seed: ?u64) !Self {
            const s: u64 = seed orelse @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
            var prng: std.Random.DefaultPrng = .init(s);
            var rand = prng.random();
            var result = try init(allocator, rows, cols);
            for (0..rows * cols) |i| {
                result.items[i] = rand.float(T);
            }
            return result;
        }

        /// Cast matrix elements to a different type (rounds when converting float to int)
        pub fn cast(self: Self, comptime TargetType: type, allocator: std.mem.Allocator) !Matrix(TargetType) {
            var result = try Matrix(TargetType).init(allocator, self.rows, self.cols);
            for (self.items, 0..) |val, i| {
                result.items[i] = switch (@typeInfo(TargetType)) {
                    .int => switch (@typeInfo(T)) {
                        .float => @intFromFloat(@round(val)),
                        .int => @intCast(val),
                        else => @compileError("Unsupported cast from " ++ @typeName(T) ++ " to " ++ @typeName(TargetType)),
                    },
                    .float => switch (@typeInfo(T)) {
                        .float => @floatCast(val),
                        .int => @floatFromInt(val),
                        else => @compileError("Unsupported cast from " ++ @typeName(T) ++ " to " ++ @typeName(TargetType)),
                    },
                    else => @compileError("Target type must be numeric"),
                };
            }
            return result;
        }

        /// Sums all the elements in a matrix.
        pub fn sum(self: Self) T {
            var accum: T = 0;
            for (self.items) |val| {
                accum += val;
            }
            return accum;
        }

        /// Computes the Frobenius norm of the matrix.
        pub fn frobeniusNorm(self: Self) T {
            comptime assert(@typeInfo(T) == .float);
            var squared_sum: T = 0;
            for (self.items) |val| {
                squared_sum += val * val;
            }
            return @sqrt(squared_sum);
        }

        /// Mean (average) of all elements
        pub fn mean(self: Self) T {
            return self.sum() / @as(T, @floatFromInt(self.items.len));
        }

        /// Variance: E[(X - μ)²]
        pub fn variance(self: Self) T {
            const mu = self.mean();
            var sum_sq_diff: T = 0;
            for (self.items) |val| {
                const diff = val - mu;
                sum_sq_diff += diff * diff;
            }
            return sum_sq_diff / @as(T, @floatFromInt(self.items.len));
        }

        /// Standard deviation: sqrt(variance)
        pub fn stdDev(self: Self) T {
            comptime assert(@typeInfo(T) == .float);
            return @sqrt(self.variance());
        }

        /// Minimum element
        pub fn min(self: Self) T {
            var min_val = self.items[0];
            for (self.items[1..]) |val| {
                if (val < min_val) {
                    min_val = val;
                }
            }
            return min_val;
        }

        /// Maximum element
        pub fn max(self: Self) T {
            var max_val = self.items[0];
            for (self.items[1..]) |val| {
                if (val > max_val) {
                    max_val = val;
                }
            }
            return max_val;
        }

        /// L1 norm (nuclear norm): sum of absolute values of all elements
        pub fn l1Norm(self: Self) T {
            var sum_abs: T = 0;
            for (self.items) |val| {
                sum_abs += @abs(val);
            }
            return sum_abs;
        }

        /// Max norm (L-infinity): maximum absolute value
        pub fn maxNorm(self: Self) T {
            var max_abs: T = 0;
            for (self.items) |val| {
                const abs_val = @abs(val);
                if (abs_val > max_abs) {
                    max_abs = abs_val;
                }
            }
            return max_abs;
        }

        /// Trace: sum of diagonal elements (square matrices only)
        pub fn trace(self: Self) T {
            assert(self.rows == self.cols);
            var sum_diag: T = 0;
            for (0..self.rows) |i| {
                sum_diag += self.at(i, i).*;
            }
            return sum_diag;
        }

        /// Result of LU decomposition
        pub const LuResult = struct {
            l: Matrix(T), // Lower triangular matrix
            u: Matrix(T), // Upper triangular matrix
            p: Matrix(T), // Permutation vector (nx1 matrix)
            sign: T, // Determinant sign (+1 or -1)

            pub fn deinit(self: *@This()) void {
                self.l.deinit();
                self.u.deinit();
                self.p.deinit();
            }
        };

        /// Compute LU decomposition with partial pivoting
        /// Returns L, U matrices and permutation vector such that PA = LU
        pub fn lu(self: Self) !LuResult {
            comptime assert(@typeInfo(T) == .float);
            const n = self.rows;
            assert(n == self.cols); // Must be square

            // Create working copy
            var work: Matrix(T) = try .init(self.allocator, n, n);
            defer work.deinit();
            @memcpy(work.items, self.items);

            // Initialize L as identity, U as zero
            var l: Matrix(T) = try .init(self.allocator, n, n);
            errdefer l.deinit();
            var u: Matrix(T) = try .init(self.allocator, n, n);
            errdefer u.deinit();

            // Initialize permutation vector
            var p: Matrix(T) = try .init(self.allocator, n, 1);
            errdefer p.deinit();
            for (0..n) |i| {
                p.items[i] = @floatFromInt(i);
            }

            // Initialize matrices
            @memset(l.items, 0);
            @memset(u.items, 0);
            for (0..n) |i| {
                l.at(i, i).* = 1.0; // L starts as identity
            }

            var sign: T = 1.0;

            // Perform LU decomposition with partial pivoting
            for (0..n) |pivot_col| {
                // Find pivot
                var max_row = pivot_col;
                var max_val = @abs(work.at(pivot_col, pivot_col).*);

                for (pivot_col + 1..n) |row_idx| {
                    const val = @abs(work.at(row_idx, pivot_col).*);
                    if (val > max_val) {
                        max_val = val;
                        max_row = row_idx;
                    }
                }

                // Check for zero pivot (singular matrix)
                if (max_val < std.math.floatEps(T) * 10) {
                    // Continue with decomposition even if singular
                    // User can check if U has zeros on diagonal
                }

                // Swap rows if needed
                if (max_row != pivot_col) {
                    sign = -sign;
                    // Swap in permutation vector
                    const temp_p = p.items[pivot_col];
                    p.items[pivot_col] = p.items[max_row];
                    p.items[max_row] = temp_p;

                    // Swap rows in work matrix
                    for (0..n) |j| {
                        const temp = work.at(pivot_col, j).*;
                        work.at(pivot_col, j).* = work.at(max_row, j).*;
                        work.at(max_row, j).* = temp;
                    }

                    // Swap rows in L (only the part already computed)
                    for (0..pivot_col) |j| {
                        const temp = l.at(pivot_col, j).*;
                        l.at(pivot_col, j).* = l.at(max_row, j).*;
                        l.at(max_row, j).* = temp;
                    }
                }

                // Copy pivot row to U
                for (pivot_col..n) |j| {
                    u.at(pivot_col, j).* = work.at(pivot_col, j).*;
                }

                // Compute L column and eliminate
                for (pivot_col + 1..n) |row_idx| {
                    if (@abs(work.at(pivot_col, pivot_col).*) > std.math.floatEps(T)) {
                        const factor = work.at(row_idx, pivot_col).* / work.at(pivot_col, pivot_col).*;
                        l.at(row_idx, pivot_col).* = factor;

                        for (pivot_col + 1..n) |col_idx| {
                            work.at(row_idx, col_idx).* -= factor * work.at(pivot_col, col_idx).*;
                        }
                    }
                }
            }

            return .{
                .l = l,
                .u = u,
                .p = p,
                .sign = sign,
            };
        }

        /// Computes the determinant of the matrix using analytical formulas for small matrices
        /// and LU decomposition for larger matrices
        pub fn determinant(self: Self) !T {
            comptime assert(@typeInfo(T) == .float);
            assert(self.rows == self.cols);
            assert(self.rows > 0);

            const n = self.rows;

            // Use analytical formulas for small matrices (more efficient)
            return switch (n) {
                1 => self.at(0, 0).*,
                2 => self.at(0, 0).* * self.at(1, 1).* -
                    self.at(0, 1).* * self.at(1, 0).*,
                3 => self.at(0, 0).* * self.at(1, 1).* * self.at(2, 2).* +
                    self.at(0, 1).* * self.at(1, 2).* * self.at(2, 0).* +
                    self.at(0, 2).* * self.at(1, 0).* * self.at(2, 1).* -
                    self.at(0, 2).* * self.at(1, 1).* * self.at(2, 0).* -
                    self.at(0, 1).* * self.at(1, 0).* * self.at(2, 2).* -
                    self.at(0, 0).* * self.at(1, 2).* * self.at(2, 1).*,
                else => blk: {
                    // Use LU decomposition for larger matrices
                    var lu_result = try self.lu();
                    defer lu_result.deinit();

                    // det(A) = sign * product of diagonal elements of U
                    var det = lu_result.sign;
                    for (0..n) |i| det *= lu_result.u.at(i, i).*;
                    break :blk det;
                },
            };
        }

        pub const QrResult = struct {
            q: Matrix(T), // Orthogonal matrix (m×n)
            r: Matrix(T), // Upper triangular matrix (n×n)
            perm: []usize, // Column permutation indices (length n)
            rank: usize, // Numerical rank of the matrix
            col_norms: []T, // Final column norms after pivoting (diagnostic)
            allocator: std.mem.Allocator,

            pub fn deinit(self: *@This()) void {
                self.q.deinit();
                self.r.deinit();
                self.allocator.free(self.perm);
                self.allocator.free(self.col_norms);
            }

            /// Get the permutation as a matrix if needed
            /// Since perm[j] tells us which original column is at position j,
            /// the permutation matrix P should satisfy: A*P has column perm[j] of A at position j
            pub fn permutationMatrix(self: *const @This()) !Matrix(T) {
                const n = self.perm.len;
                var p: Matrix(T) = try .initAll(self.allocator, n, n, 0);
                // P[i,j] = 1 if original column i is at position j
                // Since perm[j] = i means original column i is at position j
                for (0..n) |j| {
                    p.at(self.perm[j], j).* = 1;
                }
                return p;
            }
        };

        /// Compute QR decomposition with column pivoting using Modified Gram-Schmidt algorithm
        /// Returns Q, R matrices and permutation such that A*P = Q*R where Q is orthogonal and R is upper triangular
        /// Also computes the numerical rank of the matrix
        pub fn qr(self: Self) !QrResult {
            comptime assert(@typeInfo(T) == .float);
            const m = self.rows;
            const n = self.cols;

            // Initialize matrices
            var q: Matrix(T) = try .init(self.allocator, m, n);
            errdefer q.deinit();
            var r: Matrix(T) = try .init(self.allocator, n, n);
            errdefer r.deinit();

            // Initialize permutation and column norms
            const perm = try self.allocator.alloc(usize, n);
            errdefer self.allocator.free(perm);
            const col_norms = try self.allocator.alloc(T, n);
            errdefer self.allocator.free(col_norms);

            // Initialize permutation as identity
            for (0..n) |i| {
                perm[i] = i;
            }

            // Copy A to Q (will be modified in-place)
            @memcpy(q.items, self.items);

            // Initialize R as zero
            @memset(r.items, 0);

            // Compute initial column norms
            for (0..n) |j| {
                var norm_sq: T = 0;
                for (0..m) |i| {
                    const val = q.at(i, j).*;
                    norm_sq += val * val;
                }
                col_norms[j] = norm_sq;
            }

            // Compute tolerance for rank determination
            // Find maximum initial column norm for scaling
            var max_norm: T = 0;
            for (0..n) |j| {
                max_norm = @max(max_norm, @sqrt(col_norms[j]));
            }
            const eps = std.math.floatEps(T);
            // Use a practical tolerance that accounts for accumulated rounding errors
            // Standard practice is to use sqrt(eps) * norm for rank determination
            const sqrt_eps = @sqrt(eps);
            const tol = sqrt_eps * @as(T, @floatFromInt(@max(m, n))) * max_norm;

            var computed_rank: usize = 0;

            // Modified Gram-Schmidt with column pivoting
            for (0..n) |k| {

                // Find column with maximum norm from k to n-1
                var max_col = k;
                var max_col_norm = col_norms[k];
                for (k + 1..n) |j| {
                    if (col_norms[j] > max_col_norm) {
                        max_col_norm = col_norms[j];
                        max_col = j;
                    }
                }

                // Swap columns if needed
                if (max_col != k) {
                    // Swap in Q
                    for (0..m) |i| {
                        const temp = q.at(i, k).*;
                        q.at(i, k).* = q.at(i, max_col).*;
                        q.at(i, max_col).* = temp;
                    }
                    // Swap in R (for already computed rows)
                    for (0..k) |i| {
                        const temp = r.at(i, k).*;
                        r.at(i, k).* = r.at(i, max_col).*;
                        r.at(i, max_col).* = temp;
                    }
                    // Swap in permutation
                    const temp_perm = perm[k];
                    perm[k] = perm[max_col];
                    perm[max_col] = temp_perm;
                    // Swap column norms
                    const temp_norm = col_norms[k];
                    col_norms[k] = col_norms[max_col];
                    col_norms[max_col] = temp_norm;
                }

                // Compute R[k,k] = ||Q[:,k]||
                r.at(k, k).* = @sqrt(col_norms[k]);

                // Check for rank deficiency
                if (r.at(k, k).* <= tol) {
                    // Set remaining diagonal elements to zero
                    for (k..n) |j| {
                        r.at(j, j).* = 0;
                        col_norms[j] = 0;
                    }
                    break;
                }

                // Count this as a non-zero pivot
                computed_rank += 1;

                // Normalize Q[:,k]
                const inv_norm = 1.0 / r.at(k, k).*;
                for (0..m) |i| {
                    q.at(i, k).* *= inv_norm;
                }

                // Orthogonalize remaining columns
                for (k + 1..n) |j| {
                    // Compute R[k,j] = Q[:,k]^T * Q[:,j]
                    var dot_product: T = 0;
                    for (0..m) |i| {
                        dot_product += q.at(i, k).* * q.at(i, j).*;
                    }
                    r.at(k, j).* = dot_product;

                    // Q[:,j] = Q[:,j] - R[k,j] * Q[:,k]
                    for (0..m) |i| {
                        q.at(i, j).* -= r.at(k, j).* * q.at(i, k).*;
                    }

                    // Update column norm efficiently
                    // ||v - proj||^2 = ||v||^2 - ||proj||^2
                    col_norms[j] -= dot_product * dot_product;
                    // Ensure non-negative due to rounding
                    if (col_norms[j] < 0) {
                        col_norms[j] = 0;
                    }
                }
            }

            // Store final column norms (after orthogonalization)
            for (0..n) |j| {
                col_norms[j] = @sqrt(col_norms[j]);
            }

            return .{
                .q = q,
                .r = r,
                .perm = perm,
                .rank = computed_rank,
                .col_norms = col_norms,
                .allocator = self.allocator,
            };
        }

        /// Compute the numerical rank of the matrix
        /// Uses QR decomposition with column pivoting
        /// The rank is determined by counting non-zero diagonal elements in R
        /// above a tolerance based on machine precision and matrix norm
        pub fn rank(self: Self) !usize {
            comptime assert(@typeInfo(T) == .float);
            // Compute QR decomposition with column pivoting
            var qr_result = try self.qr();
            defer qr_result.deinit();

            // The rank is already computed by the QR algorithm
            return qr_result.rank;
        }

        /// Returns a formatter for decimal notation with specified precision
        pub fn decimal(self: Self, comptime precision: u8) formatting.DecimalFormatter(Self, precision) {
            return formatting.DecimalFormatter(Self, precision){ .matrix = self };
        }

        /// Returns a formatter for scientific notation
        pub fn scientific(self: Self) formatting.ScientificFormatter(Self) {
            return formatting.ScientificFormatter(Self){ .matrix = self };
        }

        /// Performs singular value decomposition (SVD) on the matrix.
        /// Returns the decomposition A = U × Σ × V^T where:
        /// - U contains left singular vectors
        /// - Σ is a diagonal matrix of singular values (stored as a vector)
        /// - V contains right singular vectors
        ///
        /// Requires rows >= cols. See `SvdOptions` for configuration details.
        pub fn svd(self: Self, allocator: std.mem.Allocator, options: SvdOptions) !SvdResult(T) {
            comptime assert(@typeInfo(T) == .float);
            std.debug.assert(self.rows >= self.cols);
            return svd_module.svd(T, allocator, self, options);
        }

        /// Default formatting (scientific notation)
        pub fn format(self: Self, writer: *std.Io.Writer) !void {
            try formatting.formatMatrix(self, "{e}", writer);
        }

        /// Converts a Matrix to a static SMatrix with the given dimensions
        pub fn toSMatrix(self: Self, comptime rows: usize, comptime cols: usize) SMatrix(T, rows, cols) {
            assert(self.rows == rows);
            assert(self.cols == cols);

            var result: SMatrix(T, rows, cols) = .{};
            for (0..rows) |r| {
                for (0..cols) |c| {
                    result.at(r, c).* = self.at(r, c).*;
                }
            }
            return result;
        }

        /// Creates a Matrix from a static SMatrix
        pub fn fromSMatrix(allocator: std.mem.Allocator, smatrix: anytype) !Matrix(T) {
            var result = try Matrix(T).init(allocator, smatrix.rows, smatrix.cols);
            for (0..smatrix.rows) |r| {
                for (0..smatrix.cols) |c| {
                    result.at(r, c).* = smatrix.at(r, c).*;
                }
            }
            return result;
        }
    };
}

// Tests for dynamic Matrix functionality
test "dynamic matrix format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Test dynamic Matrix formatting
    var dm = try Matrix(f32).init(arena.allocator(), 2, 2);
    dm.at(0, 0).* = 3.14159;
    dm.at(0, 1).* = -2.71828;
    dm.at(1, 0).* = 1.41421;
    dm.at(1, 1).* = 0.57721;

    var buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buffer);

    // Test default format (scientific notation)
    try stream.print("{f}", .{dm});
    const result_default = buffer[0..stream.end];
    const expected_default =
        \\[ 3.14159e0  -2.71828e0 ]
        \\[ 1.41421e0   5.7721e-1 ]
    ;
    try expectEqualStrings(expected_default, result_default);

    // Test decimal(3) formatting
    stream.end = 0;
    try stream.print("{f}", .{dm.decimal(3)});
    const result_decimal3 = buffer[0..stream.end];
    const expected_decimal3 =
        \\[ 3.142  -2.718 ]
        \\[ 1.414   0.577 ]
    ;
    try expectEqualStrings(expected_decimal3, result_decimal3);

    // Test decimal(0) formatting
    stream.end = 0;
    try stream.print("{f}", .{dm.decimal(0)});
    const result_decimal0 = buffer[0..stream.end];
    const expected_decimal0 =
        \\[ 3  -3 ]
        \\[ 1   1 ]
    ;
    try expectEqualStrings(expected_decimal0, result_decimal0);

    // Test scientific formatting
    stream.end = 0;
    try stream.print("{f}", .{dm.scientific()});
    const result_scientific = buffer[0..stream.end];
    const expected_scientific =
        \\[ 3.14159e0  -2.71828e0 ]
        \\[ 1.41421e0   5.7721e-1 ]
    ;
    try expectEqualStrings(expected_scientific, result_scientific);
}

test "matrix conversions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Test SMatrix to Matrix conversion
    const static_matrix = SMatrix(f64, 2, 3).init(.{
        .{ 1.5, 2.5, 3.5 },
        .{ 4.5, 5.5, 6.5 },
    });
    const dynamic_matrix = try static_matrix.toMatrix(arena.allocator());
    try expectEqual(@as(usize, 2), dynamic_matrix.rows);
    try expectEqual(@as(usize, 3), dynamic_matrix.cols);
    try expectEqual(@as(f64, 1.5), dynamic_matrix.at(0, 0).*);
    try expectEqual(@as(f64, 6.5), dynamic_matrix.at(1, 2).*);

    // Test round-trip conversion: SMatrix -> Matrix -> SMatrix
    const back_to_static = dynamic_matrix.toSMatrix(2, 3);
    for (0..2) |r| {
        for (0..3) |c| {
            try expectEqual(static_matrix.at(r, c).*, back_to_static.at(r, c).*);
        }
    }
}

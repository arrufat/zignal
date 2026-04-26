//! Chain(T): a matrix-operation chain.
//!
//! Wraps a `Matrix(T)` for fluent chaining. Each chainable op executes
//! eagerly, frees the previous intermediate, and stores the new result on
//! the same `Chain`. Errors are deferred onto an internal field and
//! surfaced by `toOwned()`.
//!
//! ## Usage
//!
//! ```zig
//! var p = m.chain();
//! defer p.deinit();
//! const result = try p.dot(b).transpose().scale(0.5).toOwned();
//! defer result.deinit();
//! ```
//!
//! `defer p.deinit()` is safe whether or not `toOwned()` ran — `toOwned`
//! clears ownership of the final matrix so a subsequent `deinit` is a no-op.
//!
//! ## Single-op shortcut
//!
//! For one-shot operations, call the method directly on `Matrix(T)`:
//!
//! ```zig
//! const result = try a.dot(b);
//! defer result.deinit();
//! ```
//!
//! `Chain` is only needed when chaining 2+ ops, where its eager-free
//! behaviour avoids the leak-by-default that an arena workaround used to
//! address.

const std = @import("std");
const matrix_module = @import("Matrix.zig");
const Matrix = matrix_module.Matrix;
const MatrixError = matrix_module.MatrixError;

pub fn Chain(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The current "head" of the chain — the result of the last successful op,
        /// or the borrowed input matrix if no ops have run yet.
        current: Matrix(T),
        /// True iff `current` is heap-owned by Chain. The initial input is
        /// borrowed (false); every chainable op produces an owned result (true).
        owns_current: bool,
        /// Allocator used for newly produced matrices. Inherited from the input.
        allocator: std.mem.Allocator,
        /// Deferred error from any chainable op; surfaced by `toOwned()`.
        err: ?MatrixError = null,

        /// Lift a `Matrix(T)` into a `Chain(T)`. The matrix is borrowed —
        /// callers retain ownership and remain responsible for its `deinit`.
        pub fn from(matrix: Matrix(T)) Self {
            return .{
                .current = matrix,
                .owns_current = false,
                .allocator = matrix.allocator,
            };
        }

        /// Free the chain's current intermediate (if owned). Safe to call
        /// after `toOwned()` (in which case it's a no-op) or to abort a chain
        /// without consuming the result.
        pub fn deinit(self: *Self) void {
            if (self.owns_current) self.current.deinit();
            self.owns_current = false;
        }

        /// Terminal operation — yields the final matrix or surfaces the
        /// deferred error. On success, ownership of the result transfers to
        /// the caller and a subsequent `deinit` becomes a no-op.
        ///
        /// Calling `toOwned()` on a chain with zero ops returns a duplicate
        /// of the input (since the caller didn't transfer ownership of it).
        pub fn toOwned(self: *Self) MatrixError!Matrix(T) {
            if (self.err) |e| {
                self.deinit();
                return e;
            }
            if (!self.owns_current) {
                // Zero-op chain: input is borrowed; return a fresh copy.
                return self.current.dupe(self.allocator);
            }
            const out = self.current;
            self.owns_current = false;
            return out;
        }

        // === Internal helper ===

        /// Run a `Matrix(T)`-method that returns `MatrixError!Matrix(T)` and
        /// install the result as the new `current`, freeing the previous one
        /// if owned. On failure, store the error and leave `current` alone.
        fn step(self: *Self, result: MatrixError!Matrix(T)) *Self {
            if (self.err != null) return self;
            const new_matrix = result catch |e| {
                self.err = e;
                return self;
            };
            if (self.owns_current) self.current.deinit();
            self.current = new_matrix;
            self.owns_current = true;
            return self;
        }

        // === Chainable operations ===

        /// Element-wise addition.
        pub fn add(self: *Self, other: Matrix(T)) *Self {
            if (self.err != null) return self;
            return self.step(self.current.add(other));
        }

        /// Element-wise subtraction.
        pub fn sub(self: *Self, other: Matrix(T)) *Self {
            if (self.err != null) return self;
            return self.step(self.current.sub(other));
        }

        /// Element-wise multiplication (Hadamard product).
        pub fn times(self: *Self, other: Matrix(T)) *Self {
            if (self.err != null) return self;
            return self.step(self.current.times(other));
        }

        /// Scale all elements by a scalar.
        pub fn scale(self: *Self, value: T) *Self {
            if (self.err != null) return self;
            return self.step(self.current.scale(value));
        }

        /// Add a scalar to every element.
        pub fn offset(self: *Self, value: T) *Self {
            if (self.err != null) return self;
            return self.step(self.current.offset(value));
        }

        /// Raise every element to power `n`.
        pub fn pow(self: *Self, n: T) *Self {
            if (self.err != null) return self;
            return self.step(self.current.pow(n));
        }

        /// Apply a function element-wise. Extra `args` are forwarded to `func`
        /// after the element value.
        pub fn apply(self: *Self, comptime func: anytype, args: anytype) *Self {
            if (self.err != null) return self;
            return self.step(self.current.apply(func, args));
        }

        /// Transpose.
        pub fn transpose(self: *Self) *Self {
            if (self.err != null) return self;
            return self.step(self.current.transpose());
        }

        /// Matrix multiplication (dot product).
        pub fn dot(self: *Self, other: Matrix(T)) *Self {
            if (self.err != null) return self;
            return self.step(self.current.dot(other));
        }

        /// Scaled matrix multiplication: α * A * B.
        pub fn scaledDot(self: *Self, other: Matrix(T), alpha: T) *Self {
            if (self.err != null) return self;
            return self.step(self.current.scaledDot(other, alpha));
        }

        /// Matrix multiplication with right-side transpose: A * B^T.
        pub fn dotTranspose(self: *Self, other: Matrix(T)) *Self {
            if (self.err != null) return self;
            return self.step(self.current.dotTranspose(other));
        }

        /// Matrix multiplication with left-side transpose: A^T * B.
        pub fn transposeDot(self: *Self, other: Matrix(T)) *Self {
            if (self.err != null) return self;
            return self.step(self.current.transposeDot(other));
        }

        /// General matrix multiply: C = α · op(self) · op(other) + β · c
        pub fn gemm(
            self: *Self,
            trans_a: bool,
            other: Matrix(T),
            trans_b: bool,
            alpha: T,
            beta: T,
            c: ?Matrix(T),
        ) *Self {
            if (self.err != null) return self;
            return self.step(self.current.gemm(trans_a, other, trans_b, alpha, beta, c));
        }

        /// Gram matrix: A · A^T.
        pub fn gram(self: *Self) *Self {
            if (self.err != null) return self;
            return self.step(self.current.gram());
        }

        /// Covariance matrix: A^T · A.
        pub fn covariance(self: *Self) *Self {
            if (self.err != null) return self;
            return self.step(self.current.covariance());
        }

        /// Matrix inverse.
        pub fn inverse(self: *Self) *Self {
            if (self.err != null) return self;
            return self.step(self.current.inverse());
        }

        /// Moore-Penrose pseudo-inverse.
        pub fn pseudoInverse(self: *Self, options: Matrix(T).PseudoInverseOptions) *Self {
            if (self.err != null) return self;
            return self.step(self.current.pseudoInverse(options));
        }

        /// Cholesky decomposition (lower triangular L such that A = L · L^T).
        pub fn cholesky(self: *Self) *Self {
            if (self.err != null) return self;
            return self.step(self.current.cholesky());
        }

        /// Extract a submatrix.
        pub fn subMatrix(self: *Self, row_begin: u32, col_begin: u32, row_count: u32, col_count: u32) *Self {
            if (self.err != null) return self;
            return self.step(self.current.subMatrix(row_begin, col_begin, row_count, col_count));
        }

        /// Extract a single column.
        pub fn col(self: *Self, col_idx: u32) *Self {
            if (self.err != null) return self;
            return self.step(self.current.col(col_idx));
        }

        /// Extract a single row.
        pub fn row(self: *Self, row_idx: u32) *Self {
            if (self.err != null) return self;
            return self.step(self.current.row(row_idx));
        }
    };
}

test "Chain: single-op success" {
    const allocator = std.testing.allocator;
    var a: Matrix(f64) = try .initAll(allocator, 2, 2, 1.0);
    defer a.deinit();

    var p = a.chain();
    defer p.deinit();
    var r = try p.scale(2.0).toOwned();
    defer r.deinit();
    try std.testing.expectEqual(@as(f64, 2.0), r.at(0, 0).*);
}

test "Chain: multi-op chain frees intermediates" {
    const allocator = std.testing.allocator;
    var a: Matrix(f64) = try .init(allocator, 2, 2);
    defer a.deinit();
    a.at(0, 0).* = 1.0;
    a.at(0, 1).* = 2.0;
    a.at(1, 0).* = 3.0;
    a.at(1, 1).* = 4.0;

    var p = a.chain();
    defer p.deinit();
    var r = try p.scale(2.0).offset(1.0).transpose().toOwned();
    defer r.deinit();
    // (a * 2 + 1) transposed: original a={1,2,3,4} -> {3,5,7,9} -> transpose
    try std.testing.expectEqual(@as(f64, 3.0), r.at(0, 0).*);
    try std.testing.expectEqual(@as(f64, 7.0), r.at(0, 1).*);
    try std.testing.expectEqual(@as(f64, 5.0), r.at(1, 0).*);
    try std.testing.expectEqual(@as(f64, 9.0), r.at(1, 1).*);
}

test "Chain: error short-circuits and toOwned surfaces it" {
    const allocator = std.testing.allocator;
    var a: Matrix(f64) = try .initAll(allocator, 2, 3, 1.0);
    defer a.deinit();
    var b: Matrix(f64) = try .initAll(allocator, 4, 5, 1.0);
    defer b.deinit();

    var p = a.chain();
    defer p.deinit();
    try std.testing.expectError(error.DimensionMismatch, p.add(b).scale(2.0).toOwned());
}

test "Chain: zero-op chain returns a duplicate" {
    const allocator = std.testing.allocator;
    var a: Matrix(f64) = try .initAll(allocator, 2, 2, 7.0);
    defer a.deinit();

    var p = a.chain();
    defer p.deinit();
    var r = try p.toOwned();
    defer r.deinit();
    try std.testing.expectEqual(@as(f64, 7.0), r.at(0, 0).*);
    // Mutating r must not affect a.
    r.at(0, 0).* = 0;
    try std.testing.expectEqual(@as(f64, 7.0), a.at(0, 0).*);
}

test "Chain: abandoned chain (no toOwned) leaks nothing" {
    const allocator = std.testing.allocator;
    var a: Matrix(f64) = try .initAll(allocator, 2, 2, 1.0);
    defer a.deinit();
    var b: Matrix(f64) = try .initAll(allocator, 2, 2, 2.0);
    defer b.deinit();

    {
        var p = a.chain();
        defer p.deinit();
        _ = p.add(b).scale(3.0); // never toOwned
    }
    // testing.allocator panics on leaks; reaching here means deinit cleaned up.
}

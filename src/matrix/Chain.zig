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
        /// Deferred error from any chainable op; surfaced by `toOwned()`.
        err: ?MatrixError = null,

        /// Lift a `Matrix(T)` into a `Chain(T)`. The matrix is borrowed —
        /// callers retain ownership and remain responsible for its `deinit`.
        pub fn from(matrix: Matrix(T)) Self {
            return .{
                .current = matrix,
                .owns_current = false,
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
        ///
        /// Mirrors `std.ArrayList.toOwnedSlice`: after the move, the chain
        /// is reset to an empty (0×0) state so further calls don't UAF the
        /// moved buffer. Calling chainable ops on a moved chain will either
        /// error on a dimension check or operate on the empty matrix.
        pub fn toOwned(self: *Self) MatrixError!Matrix(T) {
            if (self.err) |e| {
                self.deinit();
                return e;
            }
            if (!self.owns_current) {
                // Zero-op chain: input is borrowed; return a fresh copy.
                return self.current.dupe(self.current.allocator);
            }
            const out = self.current.release();
            self.owns_current = false;
            return out;
        }

        // === Internal helper ===

        /// Run a `Matrix(T)`-method that returns `MatrixError!Matrix(T)` and
        /// install the result as the new `current`, freeing the previous one
        /// if owned. On failure, store the error and leave `current` alone.
        fn step(self: *Self, result: MatrixError!Matrix(T)) *Self {
            const new_matrix = result catch |e| {
                if (self.err == null) self.err = e;
                return self;
            };
            // If the chain already has an error, we must discard this result.
            // (Current dispatch logic prevents this, but we harden for safety).
            if (self.err != null) {
                var m = new_matrix;
                m.deinit();
                return self;
            }
            if (self.owns_current) self.current.deinit();
            self.current = new_matrix;
            self.owns_current = true;
            return self;
        }

        /// Helper to delegate a method call to `Matrix(T)`.
        fn dispatch(self: *Self, comptime name: []const u8, args: anytype) *Self {
            if (self.err != null) return self;

            // Optimization: use in-place updates if we own the current matrix
            // and the operation is element-wise.
            if (self.owns_current and comptime isElementWise(name)) {
                const in_place_name = name ++ "By";
                if (@hasDecl(Matrix(T), in_place_name)) {
                    @call(.auto, @field(Matrix(T), in_place_name), .{&self.current} ++ args) catch |e| {
                        if (self.err == null) self.err = e;
                    };
                    return self;
                }
            }

            const func = @field(Matrix(T), name);
            return self.step(@call(.auto, func, .{self.current} ++ args));
        }

        fn isElementWise(comptime name: []const u8) bool {
            const list = .{ "add", "sub", "times", "scale", "offset", "pow", "apply" };
            inline for (list) |item| {
                if (std.mem.eql(u8, name, item)) return true;
            }
            return false;
        }

        // === Chainable operations ===

        /// Element-wise addition.
        pub fn add(self: *Self, other: Matrix(T)) *Self {
            return self.dispatch("add", .{other});
        }

        /// Element-wise subtraction.
        pub fn sub(self: *Self, other: Matrix(T)) *Self {
            return self.dispatch("sub", .{other});
        }

        /// Element-wise multiplication (Hadamard product).
        pub fn times(self: *Self, other: Matrix(T)) *Self {
            return self.dispatch("times", .{other});
        }

        /// Scale all elements by a scalar.
        pub fn scale(self: *Self, value: T) *Self {
            return self.dispatch("scale", .{value});
        }

        /// Add a scalar to every element.
        pub fn offset(self: *Self, value: T) *Self {
            return self.dispatch("offset", .{value});
        }

        /// Raise every element to power `n`.
        pub fn pow(self: *Self, n: T) *Self {
            return self.dispatch("pow", .{n});
        }

        /// Apply a function element-wise. Extra `args` are forwarded to `func`
        /// after the element value.
        pub fn apply(self: *Self, comptime func: anytype, args: anytype) *Self {
            return self.dispatch("apply", .{ func, args });
        }

        /// Transpose.
        pub fn transpose(self: *Self) *Self {
            return self.dispatch("transpose", .{});
        }

        /// Matrix multiplication (dot product).
        pub fn dot(self: *Self, other: Matrix(T)) *Self {
            return self.dispatch("dot", .{other});
        }

        /// Scaled matrix multiplication: α * A * B.
        pub fn scaledDot(self: *Self, other: Matrix(T), alpha: T) *Self {
            return self.dispatch("scaledDot", .{ other, alpha });
        }

        /// Matrix multiplication with right-side transpose: A * B^T.
        pub fn dotTranspose(self: *Self, other: Matrix(T)) *Self {
            return self.dispatch("dotTranspose", .{other});
        }

        /// Matrix multiplication with left-side transpose: A^T * B.
        pub fn transposeDot(self: *Self, other: Matrix(T)) *Self {
            return self.dispatch("transposeDot", .{other});
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
            return self.dispatch("gemm", .{ trans_a, other, trans_b, alpha, beta, c });
        }

        /// Gram matrix: A · A^T.
        pub fn gram(self: *Self) *Self {
            return self.dispatch("gram", .{});
        }

        /// Covariance matrix: A^T · A.
        pub fn covariance(self: *Self) *Self {
            return self.dispatch("covariance", .{});
        }

        /// Matrix inverse.
        pub fn inverse(self: *Self) *Self {
            return self.dispatch("inverse", .{});
        }

        /// Moore-Penrose pseudo-inverse.
        pub fn pseudoInverse(self: *Self, options: Matrix(T).PseudoInverseOptions) *Self {
            return self.dispatch("pseudoInverse", .{options});
        }

        /// Cholesky decomposition (lower triangular L such that A = L · L^T).
        pub fn cholesky(self: *Self) *Self {
            return self.dispatch("cholesky", .{});
        }

        /// Extract a submatrix.
        pub fn subMatrix(self: *Self, row_begin: u32, col_begin: u32, row_count: u32, col_count: u32) *Self {
            return self.dispatch("subMatrix", .{ row_begin, col_begin, row_count, col_count });
        }

        /// Extract a single column.
        pub fn col(self: *Self, col_idx: u32) *Self {
            return self.dispatch("col", .{col_idx});
        }

        /// Extract a single row.
        pub fn row(self: *Self, row_idx: u32) *Self {
            return self.dispatch("row", .{row_idx});
        }

        /// Sum all elements across each row, returning a 1 × cols row vector.
        pub fn sumRows(self: *Self) *Self {
            return self.dispatch("sumRows", .{});
        }

        /// Sum all elements down each column, returning a rows × 1 column vector.
        pub fn sumCols(self: *Self) *Self {
            return self.dispatch("sumCols", .{});
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

test "Chain: post-toOwned state is safe to reuse and deinit" {
    const allocator = std.testing.allocator;
    var a: Matrix(f64) = try .initAll(allocator, 2, 2, 1.0);
    defer a.deinit();

    var p = a.chain();
    defer p.deinit();
    var first = try p.scale(2.0).toOwned();
    // Free the result; the chain must not retain a live pointer into it.
    first.deinit();

    // A second toOwned() on the moved chain returns a 0×0 matrix from the
    // reset empty state — not a UAF on `first`'s freed buffer.
    var second = try p.toOwned();
    defer second.deinit();
    try std.testing.expectEqual(@as(u32, 0), second.rows);
    try std.testing.expectEqual(@as(u32, 0), second.cols);
    // p.deinit() runs via defer; must also be safe on the empty state.
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

test "Chain: in-place optimization" {
    const allocator = std.testing.allocator;
    var a: Matrix(f64) = try .initAll(allocator, 2, 2, 1.0);
    defer a.deinit();

    var p = a.chain();
    defer p.deinit();

    // First op creates an owned matrix.
    _ = p.scale(2.0);
    const ptr_before = p.current.items.ptr;

    // Second element-wise op should happen in-place.
    _ = p.offset(1.0);
    const ptr_after = p.current.items.ptr;

    try std.testing.expectEqual(ptr_before, ptr_after);

    var r = try p.toOwned();
    defer r.deinit();
    try std.testing.expectEqual(@as(f64, 3.0), r.at(0, 0).*);
}

test "Chain: sumRows and sumCols" {
    const allocator = std.testing.allocator;
    var a: Matrix(f64) = try .initAll(allocator, 2, 3, 1.0);
    defer a.deinit();

    var p = a.chain();
    defer p.deinit();

    var r_rows = try p.sumRows().toOwned();
    defer r_rows.deinit();
    try std.testing.expectEqual(@as(u32, 1), r_rows.rows);
    try std.testing.expectEqual(@as(u32, 3), r_rows.cols);
    try std.testing.expectEqual(@as(f64, 2.0), r_rows.at(0, 0).*);

    var q = a.chain();
    defer q.deinit();
    var r_cols = try q.sumCols().toOwned();
    defer r_cols.deinit();
    try std.testing.expectEqual(@as(u32, 2), r_cols.rows);
    try std.testing.expectEqual(@as(u32, 1), r_cols.cols);
    try std.testing.expectEqual(@as(f64, 3.0), r_cols.at(0, 0).*);
}

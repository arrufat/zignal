//! C = alpha * op(A) * op(B) + beta * C for row-major f32 matrices.
//! Compiled to SPIR-V by build.zig; one 16x16 workgroup computes a 16x16 tile of C
//! by streaming 16x16 tiles of op(A) and op(B) through workgroup-shared memory.
const std = @import("std");
const spirv = std.spirv;

const params_mod = @import("params.zig");
const Params = params_mod.Gemm;
const tile = params_mod.gemm_tile;

// Buffers are addressed through device pointers; the array length is only a type bound.
const Buf = [1 << 28]f32;
const ConstPtr = *addrspace(.physical_storage_buffer) const Buf;
const Ptr = *addrspace(.physical_storage_buffer) Buf;

extern const params: Params addrspace(.push_constant);

var tile_a: [tile][tile]f32 addrspace(.shared) = undefined;
var tile_b: [tile][tile]f32 addrspace(.shared) = undefined;

export fn main() callconv(.{ .spirv_kernel = .{ .x = tile, .y = tile, .z = 1 } }) void {
    const lx = spirv.local_invocation_id[0];
    const ly = spirv.local_invocation_id[1];
    const row = spirv.workgroup_id[1] * tile + ly;
    const col = spirv.workgroup_id[0] * tile + lx;
    const m = params.m;
    const n = params.n;
    const k = params.k;
    const trans_a = params.flags & Params.trans_a != 0;
    const trans_b = params.flags & Params.trans_b != 0;
    const a: ConstPtr = @ptrFromInt(params.a);
    const b: ConstPtr = @ptrFromInt(params.b);
    const c: Ptr = @ptrFromInt(params.c);

    var acc: f32 = 0;
    var t: u32 = 0;
    // Every invocation runs the whole loop (barriers need uniform control flow); out-of-range
    // lanes load zeros and skip the final store.
    while (t < k) : (t += tile) {
        const ka = t + lx;
        tile_a[ly][lx] = if (row < m and ka < k)
            (if (trans_a) a[ka * m + row] else a[row * k + ka])
        else
            0;
        const kb = t + ly;
        tile_b[ly][lx] = if (kb < k and col < n)
            (if (trans_b) b[col * k + kb] else b[kb * n + col])
        else
            0;
        spirv.workgroupBarrier();
        inline for (0..tile) |i| acc += tile_a[ly][i] * tile_b[i][lx];
        spirv.workgroupBarrier();
    }
    if (row < m and col < n) {
        const idx = row * n + col;
        c[idx] = if (params.beta != 0) params.alpha * acc + params.beta * c[idx] else params.alpha * acc;
    }
}

//! C = alpha * op(A) * op(B) + beta * C for row-major f32 matrices.
//! Compiled to SPIR-V by build.zig. A 16x16 workgroup computes a 64x64 tile of C: every
//! invocation owns a 4x4 register block and the workgroup streams 64x16 tiles of op(A) and
//! 16x64 tiles of op(B) through shared memory, so each shared load feeds four multiplies.
const std = @import("std");
const spirv = std.spirv;

const params_mod = @import("params.zig");
const Params = params_mod.Gemm;
const block = params_mod.gemm_block;
const threads = params_mod.gemm_threads;
const micro = block / threads;
const kstep = params_mod.gemm_kstep;

// Buffers are addressed through device pointers; the array length is only a type bound.
const Buf = [1 << 28]f32;
const ConstPtr = *addrspace(.physical_storage_buffer) const Buf;
const Ptr = *addrspace(.physical_storage_buffer) Buf;

extern const params: Params addrspace(.push_constant);

// Both tiles are stored k-major so an invocation's four operands are adjacent.
var tile_a: [kstep][block]f32 addrspace(.shared) = undefined;
var tile_b: [kstep][block]f32 addrspace(.shared) = undefined;

const loads = block * kstep / (threads * threads);

export fn main() callconv(.{ .spirv_kernel = .{ .x = threads, .y = threads, .z = 1 } }) void {
    const lx = spirv.local_invocation_id[0];
    const ly = spirv.local_invocation_id[1];
    const tid = ly * threads + lx;
    const row0 = spirv.workgroup_id[1] * block;
    const col0 = spirv.workgroup_id[0] * block;
    const m = params.m;
    const n = params.n;
    const k = params.k;
    const trans_a = params.flags & Params.trans_a != 0;
    const trans_b = params.flags & Params.trans_b != 0;
    const a: ConstPtr = @ptrFromInt(params.a);
    const b: ConstPtr = @ptrFromInt(params.b);
    const c: Ptr = @ptrFromInt(params.c);

    var acc: [micro][micro]f32 = undefined;
    inline for (0..micro) |r| inline for (0..micro) |s| {
        acc[r][s] = 0;
    };

    var t: u32 = 0;
    // Every invocation runs the whole loop (barriers need uniform control flow); out-of-range
    // elements load zeros and skip the final store. Each load mapping walks the contiguous
    // axis of the source with consecutive invocations.
    while (t < k) : (t += kstep) {
        inline for (0..loads) |j| {
            const idx = tid + j * threads * threads;
            if (trans_a) {
                const rr = idx % block;
                const kk = idx / block;
                const row = row0 + rr;
                const ka = t + kk;
                tile_a[kk][rr] = if (row < m and ka < k) a[ka * m + row] else 0;
            } else {
                const kk = idx % kstep;
                const rr = idx / kstep;
                const row = row0 + rr;
                const ka = t + kk;
                tile_a[kk][rr] = if (row < m and ka < k) a[row * k + ka] else 0;
            }
            if (trans_b) {
                const kk = idx % kstep;
                const cc = idx / kstep;
                const col = col0 + cc;
                const kb = t + kk;
                tile_b[kk][cc] = if (kb < k and col < n) b[col * k + kb] else 0;
            } else {
                const cc = idx % block;
                const kk = idx / block;
                const col = col0 + cc;
                const kb = t + kk;
                tile_b[kk][cc] = if (kb < k and col < n) b[kb * n + col] else 0;
            }
        }
        spirv.workgroupBarrier();
        inline for (0..kstep) |i| {
            var av: [micro]f32 = undefined;
            var bv: [micro]f32 = undefined;
            inline for (0..micro) |r| av[r] = tile_a[i][ly * micro + r];
            inline for (0..micro) |s| bv[s] = tile_b[i][lx * micro + s];
            inline for (0..micro) |r| inline for (0..micro) |s| {
                acc[r][s] += av[r] * bv[s];
            };
        }
        spirv.workgroupBarrier();
    }

    inline for (0..micro) |r| {
        const row = row0 + ly * micro + r;
        inline for (0..micro) |s| {
            const col = col0 + lx * micro + s;
            if (row < m and col < n) {
                const idx = row * n + col;
                c[idx] = if (params.beta != 0) params.alpha * acc[r][s] + params.beta * c[idx] else params.alpha * acc[r][s];
            }
        }
    }
}

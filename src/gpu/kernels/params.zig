//! Push-constant layouts shared by the SPIR-V kernels and the host-side `Device`.

/// Workgroup edge for the tiled gemm kernel.
pub const gemm_tile = 16;

/// C = alpha * op(A) * op(B) + beta * C; `a`, `b`, `c` are buffer device addresses.
pub const Gemm = extern struct {
    a: u64,
    b: u64,
    c: u64,
    m: u32,
    n: u32,
    k: u32,
    flags: u32,
    alpha: f32,
    beta: f32,

    pub const trans_a: u32 = 1;
    pub const trans_b: u32 = 2;
};

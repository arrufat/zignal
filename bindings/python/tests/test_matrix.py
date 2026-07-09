import numpy as np
import pytest

import zignal


def test_matrix_construction_and_attrs():
    mat = zignal.Matrix.full(2, 3, fill_value=1.5)
    assert (mat.rows, mat.cols) == (2, 3)
    assert mat.shape == (2, 3)
    assert mat.dtype == "float64"


def test_matrix_indexing_and_assignment():
    mat = zignal.Matrix.full(2, 2, fill_value=0.0)
    mat[0, 1] = 4.2
    assert mat[0, 1] == pytest.approx(4.2)
    with pytest.raises(IndexError):
        _ = mat[2, 0]
    with pytest.raises(TypeError):
        _ = mat[0]


def test_numpy_roundtrip_and_validation():
    arr = np.ones((2, 3), dtype=np.float64)
    mat = zignal.Matrix.from_numpy(arr)
    back = mat.to_numpy()
    assert np.array_equal(arr, back)

    with pytest.raises(TypeError):
        zignal.Matrix.from_numpy(np.ones((2, 3), dtype=np.int32))
    with pytest.raises(ValueError):
        zignal.Matrix.from_numpy(np.ones((2,), dtype=np.float64))


def test_operators():
    """Test operator overloads return correct types."""
    a = zignal.Matrix([[1, 2], [3, 4]])
    b = zignal.Matrix([[5, 6], [7, 8]])

    # Matrix operations
    assert isinstance(a + b, zignal.Matrix)
    assert isinstance(a - b, zignal.Matrix)
    assert isinstance(a * b, zignal.Matrix)  # element-wise
    assert isinstance(a @ b, zignal.Matrix)  # matrix multiply

    # Scalar operations
    assert isinstance(a + 10, zignal.Matrix)
    assert isinstance(a * 2, zignal.Matrix)
    assert isinstance(2 * a, zignal.Matrix)  # rmul
    assert isinstance(a / 2, zignal.Matrix)

    # Unary
    assert isinstance(-a, zignal.Matrix)


def test_scalar_subtraction():
    """Test both normal and reflected subtraction with scalars."""
    m = zignal.Matrix([[2.0]])

    # Normal subtraction: matrix - scalar
    result = m - 10
    assert isinstance(result, zignal.Matrix)
    assert result[0, 0] == pytest.approx(-8.0)

    # Reflected subtraction: scalar - matrix (regression test)
    result = 10 - m
    assert isinstance(result, zignal.Matrix)
    assert result[0, 0] == pytest.approx(8.0)

    # More complex case
    m2 = zignal.Matrix([[1, 2], [3, 4]])
    result = 10 - m2
    assert result[0, 0] == pytest.approx(9.0)
    assert result[0, 1] == pytest.approx(8.0)
    assert result[1, 0] == pytest.approx(7.0)
    assert result[1, 1] == pytest.approx(6.0)


def test_creation_methods():
    """Test class method constructors."""
    z = zignal.Matrix.zeros(2, 3)
    assert z.shape == (2, 3)
    assert isinstance(z, zignal.Matrix)

    o = zignal.Matrix.ones(3, 2)
    assert o.shape == (3, 2)

    i = zignal.Matrix.identity(4, 4)
    assert i.shape == (4, 4)

    r = zignal.Matrix.random(2, 3, 0)
    assert r.shape == (2, 3)

    # Test random with seed
    r_seeded = zignal.Matrix.random(2, 2, seed=42)
    assert r_seeded.shape == (2, 2)


def test_transpose_and_properties():
    """Test transpose method and T property."""
    m = zignal.Matrix([[1, 2, 3], [4, 5, 6]])
    assert m.shape == (2, 3)

    t = m.transpose()
    assert isinstance(t, zignal.Matrix)
    assert t.shape == (3, 2)

    # Test T property
    t2 = m.T
    assert isinstance(t2, zignal.Matrix)
    assert t2.shape == (3, 2)


def test_basic_methods():
    """Test basic matrix methods return correct types."""
    m = zignal.Matrix([[1, 2], [3, 4]])

    assert isinstance(m.copy(), zignal.Matrix)
    assert isinstance(m.inv(), zignal.Matrix)
    assert isinstance(m.dot(m), zignal.Matrix)


def test_statistics_methods():
    """Test statistics methods return scalars."""
    m = zignal.Matrix([[1, 2], [3, 4]])

    assert isinstance(m.sum(), float)
    assert isinstance(m.mean(), float)
    assert isinstance(m.min(), float)
    assert isinstance(m.max(), float)
    assert isinstance(m.trace(), float)
    assert isinstance(m.variance(), float)
    assert isinstance(m.std(), float)


def test_linear_algebra_methods():
    """Test linear algebra methods."""
    m = zignal.Matrix([[2, 0], [0, 3]])

    # Determinant
    assert isinstance(m.det(), float)

    # Gram and covariance
    a = zignal.Matrix([[1, 2], [3, 4], [5, 6]])
    assert isinstance(a.gram(), zignal.Matrix)
    assert isinstance(a.covariance(), zignal.Matrix)

    # Norms
    assert isinstance(m.frobenius_norm(), float)
    assert isinstance(m.l1_norm(), float)
    assert isinstance(m.max_norm(), float)
    assert isinstance(m.element_norm(), float)
    assert isinstance(m.element_norm(p=3.5), float)
    assert isinstance(m.schatten_norm(), float)
    assert isinstance(m.schatten_norm(p=1), float)
    assert isinstance(m.induced_norm(), float)
    assert isinstance(m.induced_norm(p=1), float)
    assert isinstance(m.nuclear_norm(), float)
    assert isinstance(m.spectral_norm(), float)

    import pytest

    with pytest.raises(ValueError):
        _ = m.element_norm(p=-1)
    with pytest.raises(ValueError):
        _ = m.schatten_norm(p=0.5)
    with pytest.raises(ValueError):
        _ = m.induced_norm(p=3)


def test_element_wise_operations():
    """Test element-wise operations."""
    m = zignal.Matrix([[2, 3], [4, 5]])
    result = m.pow(2)
    assert isinstance(result, zignal.Matrix)
    assert result.shape == (2, 2)


def test_extraction_methods():
    """Test row, column, and submatrix extraction."""
    m = zignal.Matrix([[1, 2, 3], [4, 5, 6], [7, 8, 9]])

    # Row extraction
    row = m.row(1)
    assert isinstance(row, zignal.Matrix)
    assert row.shape == (1, 3)

    # Column extraction
    col = m.col(2)
    assert isinstance(col, zignal.Matrix)
    assert col.shape == (3, 1)

    # Submatrix
    sub = m.submatrix(0, 1, 2, 2)
    assert isinstance(sub, zignal.Matrix)
    assert sub.shape == (2, 2)


def test_rank_and_pinv():
    """Test rank and pseudoinverse methods."""
    m = zignal.Matrix([[1, 0], [0, 1]])
    assert isinstance(m.rank(), int)
    assert m.rank() == 2

    # Pseudoinverse
    a = zignal.Matrix([[1, 2], [3, 4], [5, 6]])
    pinv = a.pinv()
    assert isinstance(pinv, zignal.Matrix)
    assert pinv.shape == (2, 3)


def test_lu_decomposition():
    """Test LU decomposition returns dict with correct structure."""
    m = zignal.Matrix([[4, 3], [6, 3]])
    result = m.lu()

    assert isinstance(result, dict)
    assert set(result.keys()) == {"l", "u", "p", "sign"}
    assert isinstance(result["l"], zignal.Matrix)
    assert isinstance(result["u"], zignal.Matrix)
    assert isinstance(result["p"], list)
    assert isinstance(result["sign"], float)


def test_qr_decomposition():
    """Test QR decomposition returns dict with correct structure."""
    m = zignal.Matrix([[1, 2], [3, 4], [5, 6]])
    result = m.qr()

    assert isinstance(result, dict)
    assert set(result.keys()) == {"q", "r", "rank", "perm", "col_norms"}
    assert isinstance(result["q"], zignal.Matrix)
    assert isinstance(result["r"], zignal.Matrix)
    assert isinstance(result["rank"], int)
    assert isinstance(result["perm"], list)
    assert isinstance(result["col_norms"], list)


def test_svd_decomposition():
    """Test SVD decomposition returns dict with correct structure."""
    m = zignal.Matrix([[1, 2], [3, 4], [5, 6]])

    # Default parameters
    result = m.svd()
    assert isinstance(result, dict)
    assert set(result.keys()) == {"u", "s", "v", "converged"}
    assert isinstance(result["u"], zignal.Matrix)
    assert isinstance(result["s"], zignal.Matrix)
    assert isinstance(result["v"], zignal.Matrix)
    assert isinstance(result["converged"], int)

    # With full_matrices=False
    result_skinny = m.svd(full_matrices=False)
    assert isinstance(result_skinny["u"], zignal.Matrix)
    assert result_skinny["u"].shape[1] <= result["u"].shape[1]

    # With compute_uv=False (still returns u, s, v based on implementation)
    result_no_uv = m.svd(compute_uv=False)
    assert isinstance(result_no_uv, dict)


def test_inplace_operators():
    """Test in-place operator overloads."""
    a = zignal.Matrix([[1, 2], [3, 4]])
    a_np = np.array([[1.0, 2.0], [3.0, 4.0]])

    a += 10
    a_np += 10
    assert np.allclose(a.to_numpy(), a_np)

    b = zignal.Matrix([[1, 1], [1, 1]])
    b_np = np.array([[1.0, 1.0], [1.0, 1.0]])
    a += b
    a_np += b_np
    assert np.allclose(a.to_numpy(), a_np)

    a -= 2
    a_np -= 2
    assert np.allclose(a.to_numpy(), a_np)

    a *= 2
    a_np *= 2
    assert np.allclose(a.to_numpy(), a_np)

    a /= 2
    a_np /= 2
    assert np.allclose(a.to_numpy(), a_np)


def test_sum_rows_cols():
    """Test row and column sums."""
    m = zignal.Matrix([[1, 2, 3], [4, 5, 6]])

    rows_sum = m.sum_rows()
    assert rows_sum.shape == (1, 3)
    assert rows_sum[0, 0] == pytest.approx(5.0)
    assert rows_sum[0, 1] == pytest.approx(7.0)
    assert rows_sum[0, 2] == pytest.approx(9.0)

    cols_sum = m.sum_cols()
    assert cols_sum.shape == (2, 1)
    assert cols_sum[0, 0] == pytest.approx(6.0)
    assert cols_sum[1, 0] == pytest.approx(15.0)


def test_solve():
    """Solve A @ x = b, single and multiple right-hand sides."""
    a = zignal.Matrix([[2, 1, 1], [4, 3, 3], [8, 7, 9]])
    b = zignal.Matrix([[7], [19], [49]])

    x = a.solve(b)
    assert x.shape == (3, 1)
    expected = np.linalg.solve(a.to_numpy(), b.to_numpy())
    np.testing.assert_allclose(x.to_numpy(), expected, atol=1e-10)

    # Multiple right-hand sides: RHS = I recovers the inverse.
    identity = zignal.Matrix.identity(3, 3)
    inv = a.solve(identity)
    np.testing.assert_allclose(inv.to_numpy(), np.linalg.inv(a.to_numpy()), atol=1e-10)


def test_solve_errors():
    """solve() rejects non-square, singular, and mismatched systems."""
    singular = zignal.Matrix([[1, 2], [2, 4]])
    b = zignal.Matrix([[1], [2]])
    with pytest.raises(ValueError):
        singular.solve(b)

    non_square = zignal.Matrix([[1, 2, 3], [4, 5, 6]])
    with pytest.raises(ValueError):
        non_square.solve(zignal.Matrix([[1], [2]]))

    good = zignal.Matrix([[1, 2], [3, 4]])
    with pytest.raises(ValueError):
        good.solve(zignal.Matrix([[1], [2], [3]]))

    with pytest.raises(TypeError):
        good.solve([[1], [2]])

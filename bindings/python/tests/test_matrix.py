"""Tests for the Matrix class."""

import numpy as np
import pytest

import zignal


def test_matrix_creation():
    """Test basic matrix creation."""
    # Create empty matrix
    m = zignal.Matrix(3, 4)
    assert m.rows == 3
    assert m.cols == 4
    assert m.shape == (3, 4)
    assert m.dtype == "float64"

    # Create with fill value
    m2 = zignal.Matrix(2, 2, fill_value=3.14)
    arr = m2.to_numpy()
    assert np.allclose(arr, 3.14)


def test_matrix_indexing():
    """Test matrix element access."""
    m = zignal.Matrix(3, 3, fill_value=1.0)

    # Set and get values
    m[0, 0] = 5.0
    m[1, 1] = 10.0
    m[2, 2] = 15.0

    assert m[0, 0] == 5.0
    assert m[1, 1] == 10.0
    assert m[2, 2] == 15.0
    assert m[0, 1] == 1.0  # Unchanged

    # Test negative indexing
    m[-1, -1] = 20.0
    assert m[2, 2] == 20.0


def test_numpy_interop():
    """Test NumPy array conversion."""
    # Create from numpy
    arr = np.array([[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]], dtype=np.float64)
    m = zignal.Matrix.from_numpy(arr)

    assert m.rows == 2
    assert m.cols == 3
    assert m[0, 0] == 1.0
    assert m[1, 2] == 6.0

    # Convert to numpy
    arr2 = m.to_numpy()
    assert arr2.shape == (2, 3)
    assert arr2.dtype == np.float64
    assert np.array_equal(arr, arr2)

    # Test zero-copy: modifying array modifies matrix
    arr[0, 0] = 99.0
    assert m[0, 0] == 99.0


def test_matrix_repr():
    """Test string representation."""
    m = zignal.Matrix(2, 3, fill_value=1.5)

    # Check repr
    repr_str = repr(m)
    assert "Matrix(2 x 3" in repr_str
    assert "float64" in repr_str

    # Check str for small matrix (should show values)
    str_repr = str(m)
    assert "1.5" in str_repr
    assert "Matrix[" in str_repr

    # Large matrix should just show dimensions
    large = zignal.Matrix(10, 10)
    str_large = str(large)
    assert "10" in str_large


def test_error_handling():
    """Test error conditions."""
    # Invalid dimensions
    with pytest.raises(ValueError):
        zignal.Matrix(0, 5)

    with pytest.raises(ValueError):
        zignal.Matrix(5, -1)

    # Invalid indexing
    m = zignal.Matrix(3, 3)
    with pytest.raises(IndexError):
        _ = m[3, 0]  # Out of bounds

    with pytest.raises(IndexError):
        m[0, 3] = 1.0  # Out of bounds

    with pytest.raises(TypeError):
        _ = m[0]  # Need tuple

    # Invalid numpy array
    with pytest.raises(TypeError):
        # Wrong dtype
        arr = np.array([[1, 2], [3, 4]], dtype=np.int32)
        zignal.Matrix.from_numpy(arr)

    with pytest.raises(ValueError):
        # Wrong dimensions
        arr = np.array([1.0, 2.0, 3.0])
        zignal.Matrix.from_numpy(arr)

    with pytest.raises(ValueError):
        # Not contiguous
        arr = np.array([[1.0, 2.0], [3.0, 4.0]])[:, ::-1]
        zignal.Matrix.from_numpy(arr)


def test_large_matrix():
    """Test with larger matrices."""
    # Create large matrix
    m = zignal.Matrix(100, 200, fill_value=2.5)
    assert m.shape == (100, 200)

    # Convert to/from numpy
    arr = m.to_numpy()
    assert arr.shape == (100, 200)
    assert np.allclose(arr, 2.5)

    # Create from large numpy array
    big_arr = np.random.randn(500, 300)
    big_m = zignal.Matrix.from_numpy(big_arr)
    assert big_m.shape == (500, 300)

    # Verify some random elements match
    assert big_m[0, 0] == big_arr[0, 0]
    assert big_m[250, 150] == big_arr[250, 150]
    assert big_m[-1, -1] == big_arr[-1, -1]


if __name__ == "__main__":
    pytest.main([__file__, "-v"])

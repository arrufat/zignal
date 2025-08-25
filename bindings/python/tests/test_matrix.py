"""Tests for the Matrix class."""

import numpy as np
import pytest

import zignal


def test_matrix_creation():
    """Test basic matrix creation."""
    # Create empty matrix
    m = zignal.Matrix.full(3, 4)
    assert m.rows == 3
    assert m.cols == 4
    assert m.shape == (3, 4)
    assert m.dtype == "float64"

    # Create with fill value
    m2 = zignal.Matrix.full(2, 2, fill_value=3.14)
    arr = m2.to_numpy()
    assert np.allclose(arr, 3.14)


def test_matrix_indexing():
    """Test matrix element access."""
    m = zignal.Matrix.full(3, 3, fill_value=1.0)

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
    m = zignal.Matrix.full(2, 3, fill_value=1.5)

    # Check repr
    repr_str = repr(m)
    assert "Matrix(2 x 3" in repr_str
    assert "float64" in repr_str

    # Check str for small matrix (should show values)
    str_repr = str(m)
    assert "1.5" in str_repr
    assert "Matrix[" in str_repr

    # Large matrix should just show dimensions
    large = zignal.Matrix.full(10, 10)
    str_large = str(large)
    assert "10" in str_large


def test_error_handling():
    """Test error conditions."""
    # Invalid dimensions
    with pytest.raises(ValueError):
        zignal.Matrix.full(0, 5)

    with pytest.raises(ValueError):
        zignal.Matrix.full(5, -1)

    # Invalid indexing
    m = zignal.Matrix.full(3, 3)
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
    m = zignal.Matrix.full(100, 200, fill_value=2.5)
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


# ============================================================================
# Tests for Matrix initialization from list of lists
# ============================================================================


def test_matrix_from_list_basic():
    """Test basic Matrix creation from list of lists."""
    # Create a 2x3 matrix
    data = [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]
    matrix = zignal.Matrix(data)

    assert matrix.rows == 2
    assert matrix.cols == 3

    # Check values using to_numpy
    arr = matrix.to_numpy()
    expected = np.array(data, dtype=np.float64)
    np.testing.assert_array_equal(arr, expected)


def test_matrix_from_list_integers():
    """Test Matrix creation from list of integers."""
    # Integers should be converted to floats
    data = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]
    matrix = zignal.Matrix(data)

    assert matrix.rows == 3
    assert matrix.cols == 3

    # Check that values are correct
    arr = matrix.to_numpy()
    expected = np.array(data, dtype=np.float64)
    np.testing.assert_array_equal(arr, expected)


def test_matrix_from_list_single_row():
    """Test Matrix creation from single row."""
    data = [[1.0, 2.0, 3.0, 4.0]]
    matrix = zignal.Matrix(data)

    assert matrix.rows == 1
    assert matrix.cols == 4

    arr = matrix.to_numpy()
    assert arr.shape == (1, 4)
    np.testing.assert_array_equal(arr, np.array(data))


def test_matrix_from_list_single_column():
    """Test Matrix creation from single column."""
    data = [[1.0], [2.0], [3.0]]
    matrix = zignal.Matrix(data)

    assert matrix.rows == 3
    assert matrix.cols == 1

    arr = matrix.to_numpy()
    assert arr.shape == (3, 1)
    np.testing.assert_array_equal(arr, np.array(data))


def test_matrix_from_list_single_element():
    """Test Matrix creation from single element."""
    data = [[42.0]]
    matrix = zignal.Matrix(data)

    assert matrix.rows == 1
    assert matrix.cols == 1
    assert matrix[0, 0] == 42.0


def test_matrix_from_list_mixed_numbers():
    """Test Matrix creation from mixed int and float."""
    data = [[1, 2.5], [3.7, 4]]
    matrix = zignal.Matrix(data)

    assert matrix.rows == 2
    assert matrix.cols == 2

    # Check individual elements
    assert matrix[0, 0] == 1.0
    assert matrix[0, 1] == 2.5
    assert matrix[1, 0] == 3.7
    assert matrix[1, 1] == 4.0


def test_matrix_from_list_empty():
    """Test that empty list raises error."""
    with pytest.raises(ValueError, match="Cannot create Matrix from empty list"):
        zignal.Matrix([])


def test_matrix_from_list_empty_row():
    """Test that empty row raises error."""
    with pytest.raises(ValueError, match="Cannot create Matrix with empty rows"):
        zignal.Matrix([[]])


def test_matrix_from_list_jagged():
    """Test that jagged arrays raise error."""
    data = [[1, 2, 3], [4, 5]]  # Second row has fewer columns
    with pytest.raises(ValueError, match="All rows must have the same number of columns"):
        zignal.Matrix(data)

    data = [[1, 2], [3, 4, 5]]  # Second row has more columns
    with pytest.raises(ValueError, match="All rows must have the same number of columns"):
        zignal.Matrix(data)


def test_matrix_from_list_not_list_of_lists():
    """Test that non-list-of-lists raises error."""
    # Single list (not nested)
    with pytest.raises(TypeError, match="Matrix data must be a list of lists"):
        zignal.Matrix([1, 2, 3])

    # List of non-lists (first element determines it's not valid)
    with pytest.raises(TypeError, match="Matrix data must be a list of lists"):
        zignal.Matrix([1, [2, 3]])


def test_matrix_from_list_non_numeric():
    """Test that non-numeric values raise error."""
    data = [["a", "b"], ["c", "d"]]
    with pytest.raises(TypeError, match="Matrix elements must be numeric"):
        zignal.Matrix(data)

    data = [[1, 2], [3, None]]
    with pytest.raises(TypeError, match="Matrix elements must be numeric"):
        zignal.Matrix(data)


def test_matrix_constructor_and_full():
    """Test Matrix constructor and full() class method."""
    # List of lists constructor
    m1 = zignal.Matrix([[1, 2], [3, 4]])
    assert m1.rows == 2
    assert m1.cols == 2

    # full() class method
    m2 = zignal.Matrix.full(3, 4)
    assert m2.rows == 3
    assert m2.cols == 4
    assert m2[0, 0] == 0.0  # Default fill value

    # full() with fill_value
    m3 = zignal.Matrix.full(2, 2, fill_value=5.0)
    assert m3[0, 0] == 5.0
    assert m3[1, 1] == 5.0


def test_matrix_from_list_with_optimization():
    """Test using list-initialized matrix with solve_assignment_problem."""
    # Create cost matrix from list
    costs = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]
    matrix = zignal.Matrix(costs)

    # Solve assignment problem
    result = zignal.solve_assignment_problem(matrix, zignal.OptimizationPolicy.MIN)

    assert isinstance(result, zignal.Assignment)
    assert len(result.assignments) == 3
    assert result.total_cost >= 0


def test_matrix_from_list_large():
    """Test creating a larger matrix from list."""
    # Create a 10x10 matrix
    data = [[float(i * 10 + j) for j in range(10)] for i in range(10)]
    matrix = zignal.Matrix(data)

    assert matrix.rows == 10
    assert matrix.cols == 10

    # Spot check some values
    assert matrix[0, 0] == 0.0
    assert matrix[5, 5] == 55.0
    assert matrix[9, 9] == 99.0


if __name__ == "__main__":
    pytest.main([__file__, "-v"])

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

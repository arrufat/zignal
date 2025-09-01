"""Test PCA functionality."""

import numpy as np
import zignal


def test_pca_basic():
    """Basic smoke test for PCA."""
    # Create PCA instance
    pca = zignal.PCA()

    # Create simple test data
    data = zignal.Matrix(
        [
            [1.0, 2.0, 3.0],
            [4.0, 5.0, 6.0],
            [7.0, 8.0, 9.0],
            [10.0, 11.0, 12.0],
        ]
    )

    # Fit PCA
    pca.fit(data, num_components=2)

    # Check basic properties
    assert pca.dim == 3
    assert pca.num_components == 2
    assert len(pca.eigenvalues) == 2
    assert len(pca.mean) == 3

    # Test projection
    coeffs = pca.project([5.0, 6.0, 7.0])
    assert len(coeffs) == 2

    # Test transform
    transformed = pca.transform(data)
    assert transformed.rows == 4
    assert transformed.cols == 2

    # Test reconstruction
    reconstructed = pca.reconstruct(coeffs)
    assert len(reconstructed) == 3


def test_pca_with_numpy():
    """Test PCA with numpy integration."""
    # Create numpy data and convert to Matrix
    np_data = np.random.randn(10, 5)
    matrix = zignal.Matrix.from_numpy(np_data)

    pca = zignal.PCA()
    pca.fit(matrix, num_components=3)

    # Transform and convert back to numpy
    transformed = pca.transform(matrix)
    transformed_np = transformed.to_numpy()

    assert transformed_np.shape == (10, 3)
    assert transformed_np.dtype == np.float64

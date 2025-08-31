"""Smoke tests for geometric transforms API."""

import zignal


class TestTransformsSmoke:
    """Smoke tests for transform API - just verify methods exist and are callable."""

    def test_similarity_transform_smoke(self):
        """Test SimilarityTransform API exists."""
        # Can construct
        transform = zignal.SimilarityTransform([(0, 0), (10, 0)], [(5, 5), (15, 5)])

        # Can project single point
        result = transform.project((5, 0))
        assert result is not None

        # Can project list
        results = transform.project([(0, 0), (5, 5)])
        assert results is not None

    def test_affine_transform_smoke(self):
        """Test AffineTransform API exists."""
        # Can construct
        transform = zignal.AffineTransform([(0, 0), (10, 0), (0, 10)], [(1, 1), (11, 2), (2, 11)])

        # Can project
        result = transform.project((5, 5))
        assert result is not None

        # Can project list
        results = transform.project([(0, 0), (5, 5)])
        assert results is not None

    def test_projective_transform_smoke(self):
        """Test ProjectiveTransform API exists."""
        # Can construct
        transform = zignal.ProjectiveTransform(
            [(0, 0), (10, 0), (10, 10), (0, 10)], [(1, 1), (9, 2), (8, 8), (2, 9)]
        )

        # Can project
        result = transform.project((5, 5))
        assert result is not None

        # Can project list
        results = transform.project([(2, 2), (8, 8)])
        assert results is not None

    def test_transform_with_warp(self):
        """Test transforms work with Image.warp()."""
        img = zignal.Image(10, 10)

        # Similarity with warp
        sim = zignal.SimilarityTransform([(2, 2), (8, 2)], [(3, 3), (7, 3)])
        warped = img.warp(sim)
        assert warped is not None

        # Affine with warp
        aff = zignal.AffineTransform([(0, 0), (10, 0), (0, 10)], [(1, 1), (9, 1), (1, 9)])
        warped = img.warp(aff)
        assert warped is not None

        # Projective with warp
        proj = zignal.ProjectiveTransform(
            [(0, 0), (10, 0), (10, 10), (0, 10)], [(1, 1), (9, 1), (9, 9), (1, 9)]
        )
        warped = img.warp(proj)
        assert warped is not None

        # With options
        warped = img.warp(sim, shape=(20, 20))
        assert warped is not None

        warped = img.warp(sim, method=zignal.Interpolation.BICUBIC)
        assert warped is not None

import pytest
import zignal


class TestTransforms:
    def test_similarity_transform(self):
        # Can construct
        transform = zignal.SimilarityTransform([(0, 0), (10, 0)], [(5, 5), (15, 5)])

        # Can project single point
        result = transform.project((5, 0))
        assert result is not None

        # Can project list
        results = transform.project([(0, 0), (5, 5)])
        assert results is not None

    def test_affine_transform(self):
        # Can construct
        transform = zignal.AffineTransform([(0, 0), (10, 0), (0, 10)], [(1, 1), (11, 2), (2, 11)])

        # Can project
        result = transform.project((5, 5))
        assert result is not None

        # Can project list
        results = transform.project([(0, 0), (5, 5)])
        assert results is not None

    def test_projective_transform(self):
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

    def test_similarity_transform_rank_deficient(self):
        with pytest.raises(ValueError, match="rank deficient"):
            zignal.SimilarityTransform([(0, 0), (0, 0)], [(1, 1), (1, 1)])

    def test_affine_transform_rank_deficient(self):
        with pytest.raises(ValueError, match="rank deficient"):
            zignal.AffineTransform([(0, 0), (1, 0), (2, 0)], [(0, 0), (1, 0), (2, 0)])

    def test_projective_transform_rank_deficient(self):
        with pytest.raises(ValueError, match="rank deficient"):
            zignal.ProjectiveTransform(
                [(0, 0), (1, 0), (2, 0), (3, 0)],
                [(0, 0), (1, 0), (2, 0), (3, 0)],
            )

    def test_transform_with_warp(self):
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

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

    def test_rotate_with_border(self):
        import math
        img = zignal.Image(10, 10, dtype=zignal.Rgb)
        img.fill(zignal.Rgb(255, 255, 255))

        # Rotate 45 degrees
        # Default border (ZERO)
        rotated_default = img.rotate(math.radians(45))
        assert rotated_default is not None
        assert rotated_default.rows > 10
        assert rotated_default.cols > 10
        # Corner should be black
        px = rotated_default[0, 0]
        assert (px.r, px.g, px.b) == (0, 0, 0)

        # Zero border explicit
        rotated_zero = img.rotate(math.radians(45), border=zignal.BorderMode.ZERO)
        assert rotated_zero is not None
        px = rotated_zero[0, 0]
        assert (px.r, px.g, px.b) == (0, 0, 0)

        # Nearest neighbor and replicate border
        rotated_replicate = img.rotate(
            math.radians(45),
            method=zignal.Interpolation.NEAREST_NEIGHBOR,
            border=zignal.BorderMode.REPLICATE
        )
        assert rotated_replicate is not None
        # Corner should be white (replicated)
        px = rotated_replicate[0, 0]
        assert (px.r, px.g, px.b) == (255, 255, 255)

    def test_extract_with_border(self):
        import math
        img = zignal.Image(10, 10, dtype=zignal.Rgb)
        img.fill(zignal.Rgb(255, 255, 255))
        rect = zignal.Rectangle(-5, -5, 5, 5)

        # Extract with default border (ZERO)
        extracted_default = img.extract(rect)
        assert extracted_default is not None
        # Should be black (0,0,0) in top-left region as default is ZERO
        tl = extracted_default[0, 0]
        assert (tl.r, tl.g, tl.b) == (0, 0, 0)

        # Extract with explicit mirror border
        extracted_mirror = img.extract(rect, border=zignal.BorderMode.MIRROR)
        assert extracted_mirror is not None
        # Should NOT be black (it mirrors the white content)
        tl = extracted_mirror[0, 0]
        # Mirroring at -5 for size 10 image (0..9):
        # -1 -> 1, -2 -> 2, ... -5 -> 5?
        # Let's just check it's not black, assuming white background
        assert (tl.r, tl.g, tl.b) == (255, 255, 255)

        # Extract with replicate border
        extracted_replicate = img.extract(rect, border=zignal.BorderMode.REPLICATE)
        assert extracted_replicate is not None
        # Should be white (255,255,255) as it replicates the edge
        tl = extracted_replicate[0, 0]
        assert (tl.r, tl.g, tl.b) == (255, 255, 255)

    def test_rotate_angle_validation(self):
        import math
        img = zignal.Image(10, 10, dtype=zignal.Rgb)
        
        # NaN should raise ValueError
        with pytest.raises(ValueError, match="Angle must be a finite number"):
            img.rotate(float('nan'))
            
        # Infinity should raise ValueError
        with pytest.raises(ValueError, match="Angle must be a finite number"):
            img.rotate(float('inf'))
            
        # Out of f32 range should raise ValueError
        with pytest.raises(ValueError, match="Angle must be a finite number"):
            img.rotate(1e39)




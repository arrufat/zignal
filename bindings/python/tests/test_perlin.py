from __future__ import annotations

import math

import pytest

import zignal


MAX_OCTAVES = 32
MAX_LACUNARITY = 16.0


def test_perlin_defaults_and_amplitude_scaling():
    base = zignal.perlin(0.125, 0.5, 0.25)
    assert isinstance(base, float)

    scale = 7.5
    scaled = zignal.perlin(0.125, 0.5, 0.25, amplitude=scale)
    assert scaled == pytest.approx(base * scale)


def test_perlin_accepts_custom_parameters():
    value = zignal.perlin(
        0.2,
        0.4,
        0.1,
        amplitude=1.2,
        frequency=2.5,
        octaves=3,
        persistence=0.42,
        lacunarity=2.1,
    )
    assert isinstance(value, float)
    # Ensure octaves/persistence influence the result relative to single octave
    single_octave = zignal.perlin(0.2, 0.4, 0.1, octaves=1, persistence=0.5, lacunarity=2.0)
    assert not math.isclose(value, single_octave)


INVALID_PARAMETER_CASES = [
    pytest.param({"amplitude": 0.0}, r"amplitude must be between", id="amplitude-nonpositive"),
    pytest.param({"frequency": 0.0}, r"frequency must be between", id="frequency-nonpositive"),
    pytest.param({"octaves": 0}, r"octaves must be between 1 and 32", id="octaves-too-small"),
    pytest.param(
        {"persistence": -0.1}, r"persistence must be between 0 and 1", id="persistence-negative"
    ),
    pytest.param(
        {"persistence": 1.1}, r"persistence must be between 0 and 1", id="persistence-gt-one"
    ),
    pytest.param(
        {"lacunarity": 0.5}, r"lacunarity must be between 1 and 16", id="lacunarity-too-small"
    ),
    pytest.param(
        {"lacunarity": MAX_LACUNARITY + 1},
        r"lacunarity must be between 1 and 16",
        id="lacunarity-too-large",
    ),
    pytest.param(
        {"octaves": MAX_OCTAVES + 1}, r"octaves must be between 1 and 32", id="octaves-too-large"
    ),
]


@pytest.mark.parametrize(("kwargs", "message"), INVALID_PARAMETER_CASES)
def test_perlin_rejects_invalid_parameters(kwargs: dict[str, float], message: str) -> None:
    with pytest.raises(ValueError, match=message):
        zignal.perlin(0.0, 0.0, **kwargs)

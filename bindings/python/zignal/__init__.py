"""zero-dependency image processing library."""

import os

# Import the native extension placed by `zig build python-bindings` or `uv pip install .`
try:
    from ._zignal import *  # type: ignore
    from ._zignal import __version__  # type: ignore
except Exception as e:  # pragma: no cover - clearer error for missing build
    pkg_dir = os.path.dirname(__file__)
    raise ImportError(
        "Failed to import zignal native extension.\n"
        "Build it with: `zig build python-bindings` (dev) or install with `uv pip install .`.\n"
        f"Expected extension next to this file: {pkg_dir}/_zignal.*"
    ) from e

# Dynamically populate __all__ from the native module
__all__ = [name for name in globals() if not name.startswith("_")]

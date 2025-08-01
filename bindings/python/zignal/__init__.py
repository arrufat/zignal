"""zero-dependency image processing library."""

import importlib.util
import os

# Try the import
try:
    from ._zignal import *
except ImportError as e:
    # Try alternative import methods for development/debugging
    pkg_dir = os.path.dirname(__file__)

    # Debug: List all files in the package directory
    try:
        all_files = os.listdir(pkg_dir)
    except Exception:
        all_files = []

    # Find the actual extension file
    zignal_path = None
    for file in all_files:
        if file.startswith("_zignal") and (
            file.endswith(".so") or file.endswith(".pyd") or file.endswith(".dylib")
        ):
            zignal_path = os.path.join(pkg_dir, file)
            break

    if zignal_path and os.path.exists(zignal_path):
        try:
            spec = importlib.util.spec_from_file_location("_zignal", zignal_path)
            if spec and spec.loader:
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
                # Import everything from the module
                for name in dir(module):
                    if not name.startswith("_"):
                        globals()[name] = getattr(module, name)
            else:
                raise ImportError("Could not create module spec")
        except Exception as manual_e:
            raise ImportError(f"Failed to load _zignal extension: {manual_e}") from e
    else:
        # Provide detailed error information for debugging
        extension_files = [f for f in all_files if f.startswith("_zignal")]
        all_extensions = [f for f in all_files if f.endswith((".so", ".pyd", ".dylib"))]
        raise ImportError(
            f"_zignal extension not found in {pkg_dir}. "
            f"Files starting with '_zignal': {extension_files}. "
            f"All extension files: {all_extensions}. "
            f"All files: {all_files}"
        ) from e

# Get version from the native module
try:
    from ._zignal import __version__
except ImportError:
    __version__ = "unknown"

# Dynamically populate __all__ from the native module
__all__ = [
    name
    for name in globals()
    if not name.startswith("_") and name not in ["importlib", "os", "sys", "spec", "module"]
]

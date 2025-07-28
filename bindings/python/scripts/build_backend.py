"""Custom build backend for zignal Python bindings."""

import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

import setuptools.build_meta as _orig
from setuptools import Extension
from setuptools.build_meta import *  # re-export everything


def get_zig_target() -> str:
    """Get the appropriate Zig target for the current platform."""
    import platform

    system = platform.system().lower()
    machine = platform.machine().lower()

    # Map Python platform to Zig target
    if system == "linux":
        if machine in ("x86_64", "amd64"):
            return "x86_64-linux-gnu"
        elif machine in ("aarch64", "arm64"):
            return "aarch64-linux-gnu"
    elif system == "darwin":  # macOS
        if machine in ("x86_64", "amd64"):
            return "x86_64-macos-none"
        elif machine in ("arm64", "aarch64"):
            return "aarch64-macos-none"
    elif system == "windows":
        if machine in ("x86_64", "amd64"):
            return "x86_64-windows-msvc"
        elif machine in ("arm64", "aarch64"):
            return "aarch64-windows-msvc"

    # Fallback to native
    return "native"


def build_zig_extension(target: Optional[str] = None) -> Path:
    """Build the Zig extension module."""
    project_root = Path(__file__).parent.parent.parent

    # Use provided target or detect current platform
    zig_target = target or get_zig_target()

    # Build command
    cmd = ["zig", "build", "python-bindings"]
    if zig_target != "native":
        cmd.extend(["-Dtarget=" + zig_target])

    # Run build in project root
    result = subprocess.run(cmd, cwd=project_root, capture_output=True, text=True)

    if result.returncode != 0:
        print(f"Zig build failed with return code {result.returncode}", file=sys.stderr)
        print(f"stdout: {result.stdout}", file=sys.stderr)
        print(f"stderr: {result.stderr}", file=sys.stderr)
        raise RuntimeError(f"Zig build failed: {result.stderr}")

    # Find the built library
    lib_dir = project_root / "zig-out" / "lib"

    # Look for the library with different possible extensions
    extensions = [".so", ".dylib", ".dll", ".pyd"]
    library_path = None

    for ext in extensions:
        candidate = lib_dir / f"zignal{ext}"
        if candidate.exists():
            library_path = candidate
            break

    if not library_path:
        raise RuntimeError(f"Built library not found in {lib_dir}")

    return library_path


def build_wheel(
    wheel_directory: str,
    config_settings: Optional[Dict[str, Any]] = None,
    metadata_directory: Optional[str] = None,
) -> str:
    """Build a wheel with the Zig extension."""

    # Build the Zig extension
    target = None
    if config_settings:
        target = config_settings.get("zig-target")

    library_path = build_zig_extension(target)

    # Copy the built library to the package directory
    package_dir = Path(__file__).parent / "zignal"
    package_dir.mkdir(exist_ok=True)

    # Determine the correct extension name for the platform
    import platform

    if platform.system() == "Windows":
        dest_name = "zignal.pyd"
    else:
        dest_name = "zignal.so"

    dest_path = package_dir / dest_name
    shutil.copy2(library_path, dest_path)

    # Create __init__.py if it doesn't exist
    init_py = package_dir / "__init__.py"
    if not init_py.exists():
        init_py.write_text(
            '"""Zignal - Zero-dependency image processing library."""\n\nfrom .zignal import *\n'
        )

    # Call the original setuptools build_wheel
    return _orig.build_wheel(wheel_directory, config_settings, metadata_directory)


def build_sdist(
    sdist_directory: str,
    config_settings: Optional[Dict[str, Any]] = None,
) -> str:
    """Build a source distribution."""
    # For sdist, we don't need to build the extension
    return _orig.build_sdist(sdist_directory, config_settings)


def get_requires_for_build_wheel(
    config_settings: Optional[Dict[str, Any]] = None,
) -> List[str]:
    """Get build requirements for building wheels."""
    return ["setuptools>=45", "wheel"]


def get_requires_for_build_sdist(
    config_settings: Optional[Dict[str, Any]] = None,
) -> List[str]:
    """Get build requirements for building source distributions."""
    return ["setuptools>=45"]


def prepare_metadata_for_build_wheel(
    metadata_directory: str,
    config_settings: Optional[Dict[str, Any]] = None,
) -> str:
    """Prepare metadata for wheel building."""
    return _orig.prepare_metadata_for_build_wheel(metadata_directory, config_settings)

#!/usr/bin/env python3
"""Build wheels for multiple platforms using local Zig cross-compilation."""

import argparse
import os
import platform
import subprocess
import sys
from pathlib import Path
from typing import Iterable, List, Tuple


def get_native_platform():
    """Get the platform configuration for the current system.

    We return an explicit Zig target triple that uses the baseline CPU for the
    architecture instead of the implicit "native" CPU. This avoids emitting
    binaries tied to the build machine's micro-architecture (e.g. -mcpu=native),
    which can break wheels when run on older CPUs.
    """

    system = platform.system().lower()
    machine = platform.machine().lower()

    if system == "linux":
        if machine in ["x86_64", "amd64"]:
            return ("x86_64-linux-gnu", "manylinux1_x86_64", ".so")
        elif machine in ["aarch64", "arm64"]:
            return ("aarch64-linux-gnu", "manylinux1_aarch64", ".so")
    elif system == "windows":
        # Use native on Windows to avoid header parsing issues with explicit triples,
        # while relying on a baseline CPU to keep binaries portable.
        if machine in ["x86_64", "amd64"]:
            return ("native", "win_amd64", ".pyd")
        elif machine in ["aarch64", "arm64"]:
            return ("native", "win_arm64", ".pyd")
    elif system == "darwin":
        # Python extension modules are packaged as .so files even on macOS wheels
        if machine in ["x86_64", "amd64"]:
            return ("x86_64-macos-none", "macosx_10_9_x86_64", ".so")
        elif machine in ["aarch64", "arm64"]:
            return ("aarch64-macos-none", "macosx_11_0_arm64", ".so")

    # Fallback - let setuptools determine the platform
    return ("native", "", ".so")


# Platform configurations: (zig_target, wheel_platform_tag, extension)
PLATFORMS = [
    get_native_platform(),  # Native platform
    # Cross-compilation targets (requires Python headers for target platforms)
    # ("x86_64-windows-msvc", "win_amd64", ".pyd"),
    # ("x86_64-macos-none", "macosx_10_9_x86_64", ".dylib"),
    # ("aarch64-macos-none", "macosx_11_0_arm64", ".dylib"),
]


def update_version_from_zig() -> str:
    """Update pyproject.toml version from Zig build system and return the version."""
    print("\n=== Updating version from Zig build system ===")

    # Get the directory containing this script
    script_dir = Path(__file__).parent
    update_version_script = script_dir / "update_version.py"

    if not update_version_script.exists():
        print(f"Warning: update_version.py not found at {update_version_script}")
        print("Proceeding with existing version in pyproject.toml")
        return get_current_version()

    try:
        result = subprocess.run(
            [sys.executable, str(update_version_script)],
            cwd=script_dir,
            capture_output=True,
            text=True,
            check=True,
        )
        print(result.stdout.strip())

        # Extract the version from the output
        lines = result.stdout.strip().split("\n")
        for line in lines:
            if line.startswith("Zig resolved version:"):
                return line.split(":", 1)[1].strip()

        # Fallback to reading from pyproject.toml if version not found in output
        return get_current_version()

    except subprocess.CalledProcessError as e:
        print(f"Warning: Failed to update version from Zig: {e}")
        print(f"stderr: {e.stderr}")
        print("Proceeding with existing version in pyproject.toml")
        return get_current_version()


def get_current_version() -> str:
    """Get the current version from pyproject.toml."""
    script_dir = Path(__file__).parent
    pyproject_path = script_dir.parent / "pyproject.toml"

    if not pyproject_path.exists():
        return "unknown"

    import re

    content = pyproject_path.read_text()
    match = re.search(r'^version\s*=\s*"([^"]*)"', content, re.MULTILINE)
    if match:
        return match.group(1)
    return "unknown"


def run_command(cmd: List[str], cwd: Path = None, env: dict = None) -> subprocess.CompletedProcess:
    """Run a command and return the result."""
    print(f"Running: {' '.join(cmd)}")
    if cwd:
        print(f"  in directory: {cwd}")

    result = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True)

    if result.returncode != 0:
        print(f"Command failed with return code {result.returncode}")
        print(f"stdout: {result.stdout}")
        print(f"stderr: {result.stderr}")
        raise RuntimeError(f"Command failed: {' '.join(cmd)}")

    return result


def _iter_paths(patterns: Iterable[str], base_dir: Path):
    for pattern in patterns:
        yield from base_dir.glob(pattern)


def prepare_clean_build_env(bindings_dir: Path) -> None:
    """Prepare a clean build environment by removing any precompiled extensions."""
    print("\n=== Preparing clean build environment ===")

    # Remove any existing built extensions from the package directory
    package_dir = bindings_dir / "zignal"
    for ext in (".so", ".dylib", ".pyd", ".dll"):
        for ext_file in package_dir.glob(f"*{ext}"):
            print(f"Removing existing extension: {ext_file}")
            ext_file.unlink()

    # Clean up build artefacts
    import shutil

    for path in _iter_paths(("build", "dist", "*.egg-info"), bindings_dir):
        if not path.exists():
            continue
        print(f"Removing build artefact: {path}")
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink()


def create_wheel(
    zig_target: str,
    platform_tag: str,
    expected_ext: str,
    bindings_dir: Path,
) -> Path:
    """Create a wheel for the given platform."""
    print(f"\n=== Creating wheel for {platform_tag} ===")

    # Set environment variables to control the build
    env = os.environ.copy()
    env["PLAT_NAME"] = platform_tag
    env["ZIG_TARGET"] = zig_target
    # Enforce baseline CPU for portability (avoids -mcpu=native).
    env["ZIG_CPU"] = env.get("ZIG_CPU", "baseline")
    env["ZIG_OPTIMIZE"] = env.get("ZIG_OPTIMIZE", "ReleaseFast")  # Default to ReleaseFast

    # Use python setup.py directly to build and create wheel
    # The setup.py will automatically build the Zig extension

    # Use the same Python interpreter that's running this script
    # This ensures we use the same environment (venv or system) consistently
    python_exe = sys.executable

    # Build the command - only add --plat-name if we have a specific platform tag
    cmd = [python_exe, "setup.py", "bdist_wheel"]
    if platform_tag:  # Only specify platform if we have one
        cmd.extend(["--plat-name", platform_tag])

    result = run_command(cmd, cwd=bindings_dir, env=env)

    # Find the generated wheel
    dist_dir = bindings_dir / "dist"
    wheels = list(dist_dir.glob("*.whl"))
    if not wheels:
        raise RuntimeError("No wheel file found after build")

    # Get the most recent wheel
    latest_wheel = max(wheels, key=lambda p: p.stat().st_mtime)

    print(f"Created wheel: {latest_wheel}")

    # Debug/validation: Check wheel contents include compiled extension
    import zipfile

    with zipfile.ZipFile(latest_wheel, "r") as zf:
        names = zf.namelist()
        if expected_ext and not any(name.endswith(expected_ext) for name in names):
            raise RuntimeError(
                f"Wheel {latest_wheel.name} does not contain an extension with suffix '{expected_ext}'"
            )

    # On macOS, use delocate to fix library dependencies
    if platform.system() == "Darwin" and "macos" in platform_tag:
        try:
            # Try to import delocate
            subprocess.run(
                [python_exe, "-m", "delocate", "--version"], capture_output=True, check=True
            )

            print("Running delocate to fix macOS library dependencies...")
            # Fix the wheel to make it portable across different Python installations
            subprocess.run(
                [
                    python_exe,
                    "-m",
                    "delocate.cmd.delocate_wheel",
                    "-w",
                    str(dist_dir),  # Output directory
                    "-v",  # Verbose
                    str(latest_wheel),
                ],
                check=True,
            )

            # The fixed wheel replaces the original
            print(f"Successfully delocated wheel: {latest_wheel}")

        except (subprocess.CalledProcessError, FileNotFoundError):
            print(
                "Warning: delocate not available. Wheel may not be portable across macOS Python installations."
            )
            print("Install with: pip install delocate")

    return latest_wheel


def build_all_wheels(platforms: List[Tuple[str, str, str]]) -> List[Path]:
    """Build wheels for all specified platforms."""
    script_dir = Path(__file__).parent
    bindings_dir = script_dir.parent

    # Prepare clean build environment
    prepare_clean_build_env(bindings_dir)

    wheels = []

    for zig_target, platform_tag, expected_ext in platforms:
        try:
            # Create the wheel (setup.py will build the Zig extension automatically)
            wheel_path = create_wheel(zig_target, platform_tag, expected_ext, bindings_dir)
            wheels.append(wheel_path)

        except Exception as e:
            print(f"Failed to build wheel for {platform_tag}: {e}")
            if not args.continue_on_error:
                raise

    return wheels


def main():
    parser = argparse.ArgumentParser(description="Build wheels for multiple platforms")
    parser.add_argument(
        "--platforms", nargs="*", help="Platform tags to build (default: all supported)"
    )
    parser.add_argument(
        "--continue-on-error",
        action="store_true",
        help="Continue building other platforms if one fails",
    )
    parser.add_argument(
        "--list-platforms", action="store_true", help="List all supported platforms"
    )
    parser.add_argument(
        "--optimize",
        default="ReleaseFast",
        choices=["Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall"],
        help="Zig optimization mode (default: ReleaseFast)",
    )
    parser.add_argument(
        "--skip-version-update",
        action="store_true",
        help="Skip automatic version update from Zig build system",
    )

    global args
    args = parser.parse_args()

    if args.list_platforms:
        print("Supported platforms:")
        for zig_target, platform_tag, ext in PLATFORMS:
            print(f"  {platform_tag} ({zig_target})")
        return

    # Set optimization level from command line
    os.environ["ZIG_OPTIMIZE"] = args.optimize

    # Filter platforms if specific ones were requested
    platforms_to_build = PLATFORMS
    if args.platforms:
        platforms_to_build = [
            (zig, plat, ext) for zig, plat, ext in PLATFORMS if plat in args.platforms
        ]

        if not platforms_to_build:
            print(f"No matching platforms found for: {args.platforms}")
            print("Use --list-platforms to see available platforms")
            sys.exit(1)

    # Update version from Zig build system (unless skipped)
    if args.skip_version_update:
        print("Skipping version update (--skip-version-update specified)")
        version = get_current_version()
    else:
        version = update_version_from_zig()

    print(
        f"Building wheels for {len(platforms_to_build)} platform(s) with optimization: {args.optimize}"
    )
    print(f"Version: {version}")

    wheels = build_all_wheels(platforms_to_build)

    print("\n=== Summary ===")
    print(f"Successfully built {len(wheels)} wheel(s):")
    for wheel in wheels:
        print(f"  {wheel}")

    if wheels:
        print("\nTo upload to PyPI:")
        print(f"  uv publish {' '.join(str(w) for w in wheels)}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Upload wheels to PyPI using uv."""

import argparse
import subprocess
import sys
from pathlib import Path
from typing import List


def run_command(cmd: List[str], cwd: Path = None) -> subprocess.CompletedProcess:
    """Run a command and return the result."""
    print(f"Running: {' '.join(cmd)}")
    if cwd:
        print(f"  in directory: {cwd}")
    
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    
    if result.returncode != 0:
        print(f"Command failed with return code {result.returncode}")
        print(f"stdout: {result.stdout}")
        print(f"stderr: {result.stderr}")
        raise RuntimeError(f"Command failed: {' '.join(cmd)}")
    
    print(f"stdout: {result.stdout}")
    return result


def upload_wheels(wheels: List[Path], test_pypi: bool = False, token: str = None):
    """Upload wheels to PyPI or TestPyPI."""
    if not wheels:
        print("No wheels to upload")
        return
    
    print(f"Uploading {len(wheels)} wheel(s) to {'TestPyPI' if test_pypi else 'PyPI'}")
    
    cmd = ["uv", "publish"]
    
    if test_pypi:
        cmd.extend(["--publish-url", "https://test.pypi.org/legacy/"])
    
    if token:
        cmd.extend(["--token", token])
    
    # Add wheel files
    cmd.extend(str(w) for w in wheels)
    
    try:
        run_command(cmd, cwd=Path.cwd())
        print("Upload successful!")
    except Exception as e:
        print(f"Upload failed: {e}")
        print("\nTroubleshooting:")
        print("1. Make sure you have a PyPI account and API token")
        print("2. Set your token with: export UV_PUBLISH_TOKEN=your_token_here")
        print("3. Or use --token flag: python upload_to_pypi.py --token your_token")
        print("4. For TestPyPI, use --test-pypi flag")
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="Upload wheels to PyPI")
    parser.add_argument(
        "wheels", 
        nargs="*", 
        help="Wheel files to upload (default: all .whl files in dist/)"
    )
    parser.add_argument(
        "--test-pypi", 
        action="store_true",
        help="Upload to TestPyPI instead of PyPI"
    )
    parser.add_argument(
        "--token", 
        help="PyPI API token (or set UV_PUBLISH_TOKEN environment variable)"
    )
    parser.add_argument(
        "--build-first",
        action="store_true",
        help="Build wheels first before uploading"
    )
    
    args = parser.parse_args()
    
    # Build wheels if requested
    if args.build_first:
        print("Building wheels first...")
        build_cmd = [sys.executable, "build_wheels.py"]
        run_command(build_cmd, cwd=Path(__file__).parent)
    
    # Find wheels to upload
    if args.wheels:
        wheel_paths = [Path(w) for w in args.wheels]
        # Validate that all files exist
        for wheel in wheel_paths:
            if not wheel.exists():
                print(f"Wheel file not found: {wheel}")
                sys.exit(1)
    else:
        # Find all wheels in dist directory
        dist_dir = Path(__file__).parent / "dist"
        wheel_paths = list(dist_dir.glob("*.whl"))
        
        if not wheel_paths:
            print("No wheel files found in dist/")
            print("Run 'python build_wheels.py' first or use --build-first")
            sys.exit(1)
    
    print(f"Found {len(wheel_paths)} wheel(s):")
    for wheel in wheel_paths:
        print(f"  {wheel}")
    
    # Confirm upload
    target = "TestPyPI" if args.test_pypi else "PyPI"
    response = input(f"\nUpload to {target}? [y/N]: ")
    if response.lower() not in ("y", "yes"):
        print("Upload cancelled")
        sys.exit(0)
    
    upload_wheels(wheel_paths, args.test_pypi, args.token)


if __name__ == "__main__":
    main()
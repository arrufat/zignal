#!/usr/bin/env python3
"""
Script to automatically update pyproject.toml version from Zig build system.

This script:
1. Calls `zig build version` to get the resolved version
2. Updates the version field in pyproject.toml
3. Provides a single source of truth for versioning
"""

import subprocess
import sys
import re
from pathlib import Path


def get_zig_version() -> str:
    """Get the resolved version from Zig build system."""
    try:
        # Run from the project root (three levels up from this script)
        project_root = Path(__file__).parent.parent.parent.parent
        result = subprocess.run(
            ["zig", "build", "version"],
            cwd=project_root,
            capture_output=True,
            text=True,
            check=True
        )
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"Error running 'zig build version': {e}", file=sys.stderr)
        print(f"stdout: {e.stdout}", file=sys.stderr)
        print(f"stderr: {e.stderr}", file=sys.stderr)
        sys.exit(1)
    except FileNotFoundError:
        print("Error: 'zig' command not found. Make sure Zig is installed and in PATH.", file=sys.stderr)
        sys.exit(1)


def zig_to_python_version(zig_version: str) -> str:
    """Convert Zig version format to Python PEP 440 format."""
    # Convert Zig's "0.2.0-dev.13+abc123" to Python's "0.2.0.dev13"
    # Also handle simple "0.2.0-dev" case
    
    # Pattern to match Zig version format
    pattern = r'^(\d+\.\d+\.\d+)(?:-(.+?)(?:\.(\d+))?)?(?:\+(.+))?$'
    match = re.match(pattern, zig_version)
    
    if not match:
        # If it doesn't match expected format, return as-is
        return zig_version
    
    base_version = match.group(1)  # "0.2.0"
    prerelease = match.group(2)    # "dev" or "python" etc.
    dev_number = match.group(3)    # "13" or None
    commit_hash = match.group(4)   # "abc123" or None
    
    if prerelease:
        if prerelease in ["dev", "python"]:
            # Convert to Python dev format
            if dev_number:
                return f"{base_version}.dev{dev_number}"
            else:
                return f"{base_version}.dev0"
        else:
            # Other prerelease formats, keep as-is but convert separator
            if dev_number:
                return f"{base_version}.{prerelease}{dev_number}"
            else:
                return f"{base_version}.{prerelease}0"
    else:
        # No prerelease, just return base version
        return base_version


def update_pyproject_toml(new_version: str) -> None:
    """Update the version field in pyproject.toml."""
    pyproject_path = Path(__file__).parent.parent / "pyproject.toml"

    if not pyproject_path.exists():
        print(f"Error: pyproject.toml not found at {pyproject_path}", file=sys.stderr)
        sys.exit(1)

    # Read the file
    content = pyproject_path.read_text()

    # Update the version line
    # Match: version = "anything"
    pattern = r'^version\s*=\s*"[^"]*"'
    replacement = f'version = "{new_version}"'

    new_content, count = re.subn(pattern, replacement, content, flags=re.MULTILINE)

    if count == 0:
        print("Error: Could not find version field in pyproject.toml", file=sys.stderr)
        sys.exit(1)
    elif count > 1:
        print("Warning: Multiple version fields found in pyproject.toml", file=sys.stderr)

    # Write back the updated content
    pyproject_path.write_text(new_content)
    print(f"Updated pyproject.toml version to: {new_version}")


def main():
    """Main function."""
    if len(sys.argv) > 1:
        if sys.argv[1] in ["-h", "--help"]:
            print(__doc__)
            print("\nUsage:")
            print("  python update_version.py          # Auto-update from Zig")
            print("  python update_version.py --help   # Show this help")
            return
        else:
            print(f"Unknown argument: {sys.argv[1]}", file=sys.stderr)
            print("Use --help for usage information.", file=sys.stderr)
            sys.exit(1)

    # Get version from Zig
    zig_version = get_zig_version()
    print(f"Zig resolved version: {zig_version}")

    # Convert to Python format
    python_version = zig_to_python_version(zig_version)
    print(f"Python version format: {python_version}")

    # Update pyproject.toml
    update_pyproject_toml(python_version)

    print("✅ Version synchronization complete!")


if __name__ == "__main__":
    main()

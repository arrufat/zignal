#!/usr/bin/env python3
"""
Generate API documentation for zignal Python bindings using pdoc.

This script generates static HTML documentation that can be hosted on GitHub Pages.

Usage:
    cd bindings/python
    uv run --extra docs python build_docs.py
"""

import os
import subprocess
import sys
from pathlib import Path


def main():
    """Generate documentation for zignal Python bindings."""
    # Get the directory containing this script
    script_dir = Path(__file__).parent
    bindings_dir = script_dir.parent
    project_root = bindings_dir.parent

    # Ensure we're in the right directory
    os.chdir(project_root)

    # Check if pdoc is installed
    try:
        import pdoc
    except ImportError:
        print("Error: pdoc is not installed.")
        print("Install it with: cd bindings/python && uv pip install -e '.[docs]'")
        print(
            "Or run with: cd bindings/python && uv run --extra docs python build_docs.py"
        )
        sys.exit(1)

    # Build the Python bindings first
    print("Building Python bindings...")
    result = subprocess.run(["zig", "build", "python-bindings"], capture_output=True)
    if result.returncode != 0:
        print("Error building Python bindings:")
        print(result.stderr.decode())
        sys.exit(1)

    # Install the package in development mode
    print("Installing zignal package in development mode...")
    # Check if we're in a uv environment
    if os.environ.get("UV_PROJECT_ROOT") or Path(bindings_dir / ".venv").exists():
        # Use uv pip for installation
        result = subprocess.run(
            ["uv", "pip", "install", "-e", str(bindings_dir)], capture_output=True
        )
    else:
        # Fall back to regular pip
        result = subprocess.run(
            [sys.executable, "-m", "pip", "install", "-e", str(bindings_dir)],
            capture_output=True,
        )

    if result.returncode != 0:
        print("Error installing package:")
        print(result.stderr.decode())
        sys.exit(1)

    # Import to verify it works
    try:
        import zignal

        print(f"Successfully imported zignal version {zignal.__version__}")
    except ImportError as e:
        print(f"Error importing zignal: {e}")
        print("Make sure the Python bindings are built correctly.")
        sys.exit(1)

    # Create docs directory if it doesn't exist
    docs_dir = bindings_dir / "docs"
    docs_dir.mkdir(parents=True, exist_ok=True)

    # Generate documentation
    print(f"Generating documentation in {docs_dir}...")
    cmd = [
        sys.executable,
        "-m",
        "pdoc",
        "--output-directory",
        str(docs_dir),
        "--no-show",  # Don't open browser
        "--no-show-source",  # Don't show C extension source (enables stub file usage)
        "zignal",
        "zignal._zignal",  # Document multiple modules to enable search
    ]

    result = subprocess.run(cmd, capture_output=True)
    if result.returncode != 0:
        print("Error generating documentation:")
        print(result.stderr.decode())
        sys.exit(1)

    print("Documentation generated successfully!")
    print("Search functionality enabled by documenting multiple modules!")

    # Check what files were generated
    html_files = list(docs_dir.glob("*.html"))
    if html_files:
        print(f"Generated files: {[f.name for f in html_files]}")

    # Check if search.js was generated (indicates search is enabled)
    if (docs_dir / "search.js").exists():
        print("Search functionality has been enabled!")

    print(f"Documentation is available in {docs_dir}")


if __name__ == "__main__":
    main()

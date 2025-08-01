#!/usr/bin/env python3
"""
Generate API documentation for zignal Python bindings using pdoc.

This script generates a single static HTML file with search functionality.

Usage:
    cd bindings/python
    uv run --extra docs python build_docs.py
"""

import os
import shutil
import subprocess
import sys
import tempfile
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
        subprocess.run(["pdoc", "--version"], capture_output=True, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        print("Error: pdoc is not installed.")
        print("Install it with: cd bindings/python && uv pip install -e '.[docs]'")
        print("Or run with: cd bindings/python && uv run --extra docs python build_docs.py")
        sys.exit(1)

    # Build the Python bindings first
    print("Building Python bindings...")
    result = subprocess.run(["zig", "build", "python-bindings"], capture_output=True, text=True)
    if result.returncode != 0:
        print("Error building Python bindings:")
        print(result.stderr)
        sys.exit(1)

    # Install the package in development mode
    print("Installing zignal package in development mode...")
    install_cmd = []
    if os.environ.get("UV_PROJECT_ROOT") or (bindings_dir / ".venv").exists():
        install_cmd = ["uv", "pip", "install", "-e", str(bindings_dir)]
    else:
        install_cmd = [sys.executable, "-m", "pip", "install", "-e", str(bindings_dir)]

    result = subprocess.run(install_cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print("Error installing package:")
        print(result.stderr)
        sys.exit(1)

    # Import to verify it works
    try:
        import zignal

        print(f"Successfully imported zignal version {zignal.__version__}")
    except ImportError as e:
        print(f"Error importing zignal: {e}")
        print("Make sure the Python bindings are built correctly.")
        sys.exit(1)

    # Clean and create docs directory
    docs_dir = bindings_dir / "docs"
    print(f"Preparing documentation directory: {docs_dir}")
    if docs_dir.exists():
        shutil.rmtree(docs_dir)
    docs_dir.mkdir(parents=True, exist_ok=True)

    print("Configuring stubs and dummy module for pdoc...")
    with tempfile.TemporaryDirectory() as temp_dir:
        temp_path = Path(temp_dir)

        # Create a dummy module to force pdoc into "site generation" mode,
        # which is required for the search index to be created.
        dummy_module_path = temp_path / "dummy_module.py"
        dummy_module_path.write_text(
            "'''This is a dummy module to ensure pdoc generates a search index.'''"
        )

        # Create the PEP-561 stub package for zignal
        stub_pkg_dir = temp_path / "zignal-stubs"
        stub_pkg_dir.mkdir()
        (stub_pkg_dir / "py.typed").touch()
        pyi_source_path = bindings_dir / "zignal" / "_zignal.pyi"
        shutil.copy2(pyi_source_path, stub_pkg_dir / "__init__.pyi")

        # Set PYTHONPATH to include the directory containing stubs and the dummy module
        env = os.environ.copy()
        env["PYTHONPATH"] = str(temp_path) + os.pathsep + env.get("PYTHONPATH", "")

        # Generate documentation for zignal and the dummy module
        print("Generating documentation with pdoc...")
        cmd = [
            "pdoc",
            "zignal",
            "dummy_module",
            "--output-directory",
            str(docs_dir),
            "--no-show-source",
        ]
        result = subprocess.run(cmd, env=env, capture_output=True, text=True)

        if result.returncode != 0:
            print("Error running pdoc:")
            print(result.stdout)
            print(result.stderr)
            sys.exit(1)

    # Verify output and clean up
    print("Verifying generated files and cleaning up...")
    generated_html = docs_dir / "zignal.html"
    generated_search = docs_dir / "search.js"
    dummy_html = docs_dir / "dummy_module.html"

    if dummy_html.exists():
        dummy_html.unlink()

    if not generated_html.exists():
        print("\nError: pdoc did not generate the expected HTML file.")
        sys.exit(1)

    if not generated_search.exists() or generated_search.stat().st_size == 0:
        print("\nError: pdoc did not generate a valid search index file.")
        sys.exit(1)

    # Rename zignal.html to index.html
    target_file = docs_dir / "index.html"
    generated_html.rename(target_file)

    print("\nDocumentation generated successfully!")
    print("Search functionality has been restored.")
    print(f"\nGenerated files:")
    print(f"  - {target_file.relative_to(docs_dir)}")
    print(f"  - {generated_search.relative_to(docs_dir)}")
    print(f"\nDocumentation is available in {docs_dir}")


if __name__ == "__main__":
    main()

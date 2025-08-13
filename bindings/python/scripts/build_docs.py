#!/usr/bin/env python3
"""
Generate API documentation for zignal Python bindings using pdoc.

This script generates a single static HTML file with search functionality.

Usage:
    cd bindings/python
    uv run --extra docs python build_docs.py
"""

import os
import re
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

    print("Configuring stubs and empty module for pdoc...")
    with tempfile.TemporaryDirectory() as temp_dir:
        temp_path = Path(temp_dir)

        # Create an empty module to force pdoc into "site generation" mode,
        # which is required for the search index to be created.
        empty_module_path = temp_path / "empty.py"
        empty_module_path.write_text(
            "'''An empty placeholder module used to enable pdoc's search functionality.'''"
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

        # Generate documentation for zignal and the empty module
        print("Generating documentation with pdoc...")
        cmd = [
            "pdoc",
            "zignal",
            "empty",
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

    # Verify output
    print("Verifying generated files...")
    index_html = docs_dir / "index.html"
    zignal_html = docs_dir / "zignal.html"
    empty_html = docs_dir / "empty.html"
    generated_search = docs_dir / "search.js"

    if not index_html.exists():
        print("\nError: pdoc did not generate the expected index.html file.")
        sys.exit(1)

    if not zignal_html.exists():
        print("\nError: pdoc did not generate the expected zignal.html file.")
        sys.exit(1)

    if not empty_html.exists():
        print("\nError: pdoc did not generate the expected empty.html file.")
        sys.exit(1)

    if not generated_search.exists() or generated_search.stat().st_size == 0:
        print("\nError: pdoc did not generate a valid search index file.")
        sys.exit(1)

    print("\nDocumentation generated successfully!")
    print("Search functionality has been restored.")

    # Check for type annotation issues in the generated documentation
    print("\nValidating type annotations in generated documentation...")
    validation_errors = []

    # Read the main module documentation file
    zignal_html_content = zignal_html.read_text()

    # Check for common indicators of missing type annotations
    problematic_patterns = [
        ("(unknown)", "Found '(unknown)' which indicates missing type information"),
        ("typing.Any", "Found 'typing.Any' which may indicate incomplete type stubs"),
        # Check for parameters without type annotations - look for param spans without colons
        (
            '<span class="param"><span class="n">[^<]+</span></span>',
            "Found parameter without type annotation",
        ),
    ]

    for pattern, message in problematic_patterns:
        if pattern in zignal_html_content:
            # Count occurrences for better reporting
            count = zignal_html_content.count(pattern)
            validation_errors.append(f"{message} ({count} occurrence{'s' if count != 1 else ''})")

    # Match function definitions and check if they have return type annotations
    func_pattern = r'<span class="def">def</span>\s*<span class="name">([^<]+)</span><span class="signature[^"]*">([^<]+)</span>'
    func_matches = re.finditer(func_pattern, zignal_html_content)

    for match in func_matches:
        func_name = match.group(1)
        signature = match.group(2)
        # Check if signature has return annotation (should contain ->)
        # Skip __init__ and other special methods that don't need return types
        if (
            func_name not in ["__init__", "__repr__", "__str__", "__del__"]
            and "-&gt;" not in signature
            and "return-annotation" not in match.group(0)
        ):
            validation_errors.append(
                f"Function '{func_name}' appears to be missing return type annotation"
            )

    # Report validation results
    if validation_errors:
        print("\n⚠️  Type annotation issues detected:")
        for error in validation_errors:
            print(f"  - {error}")
        print(
            "\nPlease check the generated documentation and ensure all types are properly annotated."
        )
        print("You may need to update the .pyi stub files or the generate_stubs.zig script.")
        sys.exit(1)
    else:
        print("✓ Type annotations look good!")

    print("\nGenerated files:")
    print("  - index.html (module listing)")
    print("  - zignal.html (module documentation)")
    print("  - empty.html (placeholder for search generation)")
    print("  - search.js (search index)")
    print(f"\nDocumentation is available in {docs_dir}")
    print("Open index.html to browse the documentation with working search.")


if __name__ == "__main__":
    main()

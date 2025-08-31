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

    # Check for literal "unknown" in parameters
    unknown_matches = re.findall(
        r'<span class="name">([^<]+)</span>.*?<span class="n">unknown</span>', zignal_html_content
    )
    if unknown_matches:
        for func_name in unknown_matches:
            validation_errors.append(
                f"Function/method '{func_name}' has parameter with type 'unknown'"
            )

    # Check for *args, **kwargs patterns which indicate missing stub definitions
    # Find all function/class signatures with *args or **kwargs
    # Pattern matches: <span class="name">NAME</span> followed by signature containing *args or **kwargs

    # First, find all signatures with *args
    args_pattern = r'<span class="o">\*</span><span class="n">args</span>'

    # Find all signatures with **kwargs
    kwargs_pattern = r'<span class="o">\*\*</span><span class="n">kwargs</span>'

    # For each match, backtrack to find the associated function/class name
    generic_signatures = set()

    # Find all positions of *args and **kwargs
    for pattern, desc in [(args_pattern, "*args"), (kwargs_pattern, "**kwargs")]:
        for match in re.finditer(pattern, zignal_html_content):
            # Look backwards from the match position to find the nearest <span class="name">
            pos = match.start()
            # Get substring before the match (up to 500 chars should be enough)
            before = zignal_html_content[max(0, pos - 500) : pos]

            # Find the last occurrence of <span class="name">...</span> before *args/**kwargs
            name_match = re.findall(r'<span class="name">([^<]+)</span>', before)
            if name_match:
                # Get the last (nearest) name
                func_name = name_match[-1]
                # Make sure this is part of a signature (has <span class="signature after it)
                if (
                    '<span class="signature'
                    in before[before.rfind(f'<span class="name">{func_name}</span>') :]
                ):
                    generic_signatures.add(func_name)

    if generic_signatures:
        for class_or_func in sorted(generic_signatures):
            validation_errors.append(
                f"'{class_or_func}' is using generic (*args, **kwargs) - needs proper type stub"
            )

    # Check for typing.Any which may indicate incomplete stubs
    if "typing.Any" in zignal_html_content:
        count = zignal_html_content.count("typing.Any")
        validation_errors.append(
            f"Found 'typing.Any' which may indicate incomplete type stubs ({count} occurrence{'s' if count != 1 else ''})"
        )

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

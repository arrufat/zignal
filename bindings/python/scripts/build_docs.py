#!/usr/bin/env python3
"""
Generate API documentation for zignal Python bindings using pdoc.

Usage:
    cd bindings/python
    uv run scripts/build_docs.py
"""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def main():
    # Setup paths using absolute resolution
    script_path = Path(__file__).resolve()
    project_root = script_path.parents[3]  # scripts -> python -> bindings -> zignal root
    bindings_dir = script_path.parents[1]  # scripts -> python
    os.chdir(project_root)

    # 1. Build Bindings
    print("Building Python bindings...")
    if subprocess.call(["zig", "build", "python-bindings"]) != 0:
        sys.exit("Error: Failed to build Python bindings.")

    # 2. Type Check with ty
    print("Validating type stubs with ty...")
    try:
        subprocess.check_call(["ty", "check", "bindings/python/zignal"])
        print("Success: Type annotations look good!")
    except FileNotFoundError:
        print("Warning: 'ty' not found. Install it with 'uv pip install ty'.")
    except subprocess.CalledProcessError:
        sys.exit("Error: Type validation failed!")

    # 3. Generate Docs with pdoc
    docs_dir = bindings_dir / "docs"
    if docs_dir.exists():
        shutil.rmtree(docs_dir)
    docs_dir.mkdir(parents=True, exist_ok=True)

    print("Generating documentation...")
    with tempfile.TemporaryDirectory() as temp_dir:
        temp_path = Path(temp_dir)

        # Fix for broken annotations: Create a stub package
        # This forces pdoc to read annotations from the .pyi file
        stub_pkg_dir = temp_path / "zignal-stubs"
        stub_pkg_dir.mkdir()
        (stub_pkg_dir / "py.typed").touch()

        # Copy _zignal.pyi to the stub package
        pyi_source = bindings_dir / "zignal" / "_zignal.pyi"
        shutil.copy2(pyi_source, stub_pkg_dir / "__init__.pyi")

        # Empty module to trigger site build (enables search)
        (temp_path / "empty.py").write_text("'''Search placeholder'''")

        # Update PYTHONPATH
        env = os.environ.copy()
        env["PYTHONPATH"] = str(temp_path) + os.pathsep + env.get("PYTHONPATH", "")

        # Run pdoc
        cmd = ["pdoc", "zignal", "empty", "-o", str(docs_dir), "--no-show-source"]

        if subprocess.call(cmd, env=env) != 0:
            sys.exit("Error generating documentation.")

    print(f"\nDocumentation generated in {docs_dir}")


if __name__ == "__main__":
    main()

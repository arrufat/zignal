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
    # 1. Build Bindings
    print("Building Python bindings...")
    if subprocess.call(["zig", "build", "python-bindings"]) != 0:
        sys.exit("Error: Failed to build Python bindings.")

    # 2. Type Check with ty
    print("Validating type stubs with ty...")
    try:
        subprocess.check_call(["ty", "check", "--ignore", "unresolved-import", "zignal"])
        print("Success: Type annotations look good!")
    except FileNotFoundError:
        print("Warning: 'ty' not found. Install it with 'uv pip install ty'.")
    except subprocess.CalledProcessError:
        sys.exit("Error: Type validation failed!")

    # 3. Generate Docs with pdoc
    docs_dir = Path("docs")
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
        shutil.copy2("zignal/_zignal.pyi", stub_pkg_dir / "__init__.pyi")

        # Empty module to trigger site build (enables search)
        (temp_path / "empty.py").write_text("'''Search placeholder'''")

        # Update PYTHONPATH
        env = os.environ.copy()
        env["PYTHONPATH"] = os.pathsep.join(filter(None, [str(temp_path), env.get("PYTHONPATH")]))

        # Run pdoc
        cmd = ["pdoc", "zignal", "empty", "-o", str(docs_dir), "--no-show-source"]

        if subprocess.call(cmd, env=env) != 0:
            sys.exit("Error generating documentation.")

    print(f"\nDocumentation generated in {docs_dir}")


if __name__ == "__main__":
    main()

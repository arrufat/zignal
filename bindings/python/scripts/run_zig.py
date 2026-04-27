"""Run `zig build <args>` with PYTHON_INCLUDE_DIR / PYTHON_LIBS_DIR / PYTHON_LIB_NAME
exported the same way setup.py exports them. Lets steps that need Python.h
(notably `python-stubs`) work on Windows, where build.zig has no pkg-config
fallback.
"""

import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from setup import PROJECT_ROOT, python_build_env  # noqa: E402

if __name__ == "__main__":
    env = {**os.environ, **python_build_env()}
    sys.exit(subprocess.call(["zig", "build", *sys.argv[1:]], cwd=PROJECT_ROOT, env=env))

"""
Setup script for zignal Python bindings.

Usage:
    python -m build --wheel
    pip install .

Environment Variables:
    ZIG_TARGET: The Zig compilation target (e.g., "x86_64-linux-gnu", "native").
    ZIG_OPTIMIZE: Zig optimization mode (default: "ReleaseFast").
    ZIG_CPU: Zig CPU architecture (default: "baseline").
"""

import os
import re
import shutil
import subprocess
import sys
import sysconfig
from pathlib import Path

from setuptools import Extension, find_packages, setup
from setuptools.command.build_ext import build_ext
from setuptools.dist import Distribution

PROJECT_ROOT = Path(__file__).parent.parent.parent


class ZigExtension(Extension):
    """Extension that will be built with Zig."""

    def __init__(self, name: str):
        super().__init__(name, sources=[])
        self.target = os.environ.get("ZIG_TARGET", "native")
        self.optimize = os.environ.get("ZIG_OPTIMIZE", "ReleaseFast")
        self.cpu = os.environ.get("ZIG_CPU", "baseline")


class ZigBuildExt(build_ext):
    """Custom build_ext command that uses Zig."""

    def build_extension(self, ext: ZigExtension) -> None:
        if not isinstance(ext, ZigExtension):
            return super().build_extension(ext)

        env = {**os.environ, "PYTHON_INCLUDE_DIR": sysconfig.get_path("include")}

        if sys.platform == "win32":
            libs = Path(sysconfig.get_path("stdlib")).parent / "libs"
            if libs.exists():
                env.update({
                    "PYTHON_LIBS_DIR": str(libs),
                    "PYTHON_LIB_NAME": f"python{sys.version_info.major}{sys.version_info.minor}.lib",
                })
        else:
            if (libdir := sysconfig.get_config_var("LIBDIR")) and Path(libdir).exists():
                env["PYTHON_LIBS_DIR"] = libdir
                if sys.platform == "linux":
                    env["LD_LIBRARY_PATH"] = libdir

            if sys.platform == "darwin":
                env["PYTHON_LIB_NAME"] = f"python{sys.version_info.major}.{sys.version_info.minor}"
            else:
                libname = os.path.basename(sysconfig.get_config_var("LDLIBRARY") or sysconfig.get_config_var("LIBRARY") or f"python{sys.version_info.major}.{sys.version_info.minor}")
                env["PYTHON_LIB_NAME"] = re.sub(r"^lib|(\.so|\.a|\.dylib).*$", "", libname)

        cmd = [
            "zig",
            "build",
            "python-bindings",
            f"-Doptimize={ext.optimize}",
            f"-Dcpu={ext.cpu}",
        ]
        if ext.target != "native":
            cmd.append(f"-Dtarget={ext.target}")

        print(f"Building Zig extension: {' '.join(cmd)}")
        subprocess.check_call(cmd, cwd=PROJECT_ROOT, env=env)

        # Install built library
        zig_out = PROJECT_ROOT / "zig-out" / "lib"
        built_lib = next(zig_out.glob("_zignal*"))
        dest_path = Path(self.get_ext_fullpath(ext.name))
        dest_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(built_lib, dest_path)

        # Copy stub files
        pkg_dir = Path(__file__).parent / "zignal"
        for f in ["__init__.pyi", "_zignal.pyi", "py.typed"]:
            if (src := pkg_dir / f).exists():
                shutil.copy2(src, dest_path.parent / f)


class BinaryDistribution(Distribution):
    """Distribution which always forces a binary package with platform tag."""

    def has_ext_modules(self):
        return True


def get_project_version():
    """Get version from Zig build system directly."""
    try:
        ver = subprocess.check_output(
            ["zig", "build", "version"], cwd=PROJECT_ROOT, text=True
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "0.0.0.dev0"

    if m := re.match(r"^(\d+\.\d+\.\d+)(?:-([a-zA-Z]+)(?:\.(\d+))?)?", ver):
        base, pre, num = m.groups()
        if not pre:
            return base

        # Map prerelease tag to PEP 440
        normalized = pre.lower()
        if normalized in ("a", "alpha"):
            tag = "a"
        elif normalized in ("b", "beta"):
            tag = "b"
        elif normalized in ("c", "rc", "pre", "preview"):
            tag = "rc"
        else:
            tag = ".dev"

        return f"{base}{tag}{num or 0}"

    return ver


if __name__ == "__main__":
    setup(
        version=get_project_version(),
        packages=find_packages(exclude=["tests", "tests.*"]),
        ext_modules=[ZigExtension("zignal._zignal")],
        cmdclass={"build_ext": ZigBuildExt},
        distclass=BinaryDistribution,
        zip_safe=False,
        options={"bdist_wheel": {"plat_name": os.environ.get("PLAT_NAME")}}
        if os.environ.get("PLAT_NAME")
        else {},
    )

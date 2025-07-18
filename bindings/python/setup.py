"""Setup script for zignal Python bindings."""

import os
import shutil
import subprocess
import sys
import sysconfig
from pathlib import Path
from setuptools import Extension, find_packages, setup
from setuptools.command.build_ext import build_ext
from setuptools.dist import Distribution


class ZigExtension(Extension):
    """Extension that will be built with Zig."""

    def __init__(self, name: str, zig_target: str = "native", zig_optimize: str = "ReleaseFast"):
        # Initialize with dummy source to satisfy setuptools
        super().__init__(name, sources=[])
        self.zig_target = zig_target
        self.zig_optimize = zig_optimize


class ZigBuildExt(build_ext):
    """Custom build_ext command that uses Zig."""

    def build_extension(self, ext: ZigExtension) -> None:
        if not isinstance(ext, ZigExtension):
            return super().build_extension(ext)

        print(f"Building Zig extension with target: {ext.zig_target}, optimize: {ext.zig_optimize}")

        # Find the project root (where build.zig is located)
        current_dir = Path(__file__).parent
        project_root = current_dir.parent.parent

        # Verify build.zig exists - we always build from source
        build_zig = project_root / "build.zig"
        if not build_zig.exists():
            raise RuntimeError(
                f"build.zig not found at {build_zig}. "
                f"The Python bindings must be built from the zignal project root directory "
                f"which contains the build.zig file and source code."
            )

        # Set up environment for Zig build to find Python headers and libraries
        env = os.environ.copy()

        # Get Python include directory
        python_include = sysconfig.get_path('include')
        env['PYTHON_INCLUDE_DIR'] = python_include
        print(f"Setting PYTHON_INCLUDE_DIR={python_include}")

        # On Windows and macOS, we need to provide specific Python library information
        if sys.platform == "win32":
            # Get Python library directory (usually in libs subdirectory)
            python_prefix = sysconfig.get_path('stdlib')  # Usually C:\Python313\Lib
            # Navigate up to get the root, then to libs
            python_root = Path(python_prefix).parent  # C:\Python313
            python_libs_dir = python_root / "libs"

            if python_libs_dir.exists():
                env['PYTHON_LIBS_DIR'] = str(python_libs_dir)
                print(f"Setting PYTHON_LIBS_DIR={python_libs_dir}")

                # Determine the Python library name (e.g., python313.lib)
                version_info = sys.version_info
                python_lib_name = f"python{version_info.major}{version_info.minor}.lib"
                env['PYTHON_LIB_NAME'] = python_lib_name
                print(f"Setting PYTHON_LIB_NAME={python_lib_name}")
            else:
                print(f"Warning: Python libs directory not found at {python_libs_dir}", file=sys.stderr)

        elif sys.platform == "darwin":
            # On macOS, Python can be installed as a framework or via package managers
            # Try to detect the correct library path and name
            version_info = sys.version_info
            python_lib_name = f"python{version_info.major}.{version_info.minor}"

            # Get library directory from sysconfig
            try:
                # For framework installations
                lib_dir = sysconfig.get_config_var('LIBDIR')
                if lib_dir and Path(lib_dir).exists():
                    env['PYTHON_LIBS_DIR'] = lib_dir
                    env['PYTHON_LIB_NAME'] = python_lib_name
                    print(f"Setting PYTHON_LIBS_DIR={lib_dir}")
                    print(f"Setting PYTHON_LIB_NAME={python_lib_name}")
                else:
                    # Fallback: try common framework path
                    framework_lib = f"/Library/Frameworks/Python.framework/Versions/{version_info.major}.{version_info.minor}/lib"
                    if Path(framework_lib).exists():
                        env['PYTHON_LIBS_DIR'] = framework_lib
                        env['PYTHON_LIB_NAME'] = python_lib_name
                        print(f"Setting PYTHON_LIBS_DIR={framework_lib}")
                        print(f"Setting PYTHON_LIB_NAME={python_lib_name}")
            except Exception as e:
                print(f"Warning: Could not detect macOS Python library info: {e}", file=sys.stderr)

        # Build the Zig library with optimizations
        cmd = ["zig", "build", "python-bindings", f"-Doptimize={ext.zig_optimize}"]
        if ext.zig_target != "native":
            cmd.extend([f"-Dtarget={ext.zig_target}"])

        print(f"Running: {' '.join(cmd)} in {project_root}")
        result = subprocess.run(cmd, cwd=project_root, capture_output=True, text=True, env=env)

        if result.returncode != 0:
            print(f"Zig build failed with return code {result.returncode}", file=sys.stderr)
            print(f"stdout: {result.stdout}", file=sys.stderr)
            print(f"stderr: {result.stderr}", file=sys.stderr)
            raise RuntimeError(f"Zig build failed: {result.stderr}")

        # Find the built library
        lib_dir = project_root / "zig-out" / "lib"

        # Look for the library with different possible extensions
        extensions = [".so", ".dylib", ".pyd", ".dll"]
        library_path = None

        for extension in extensions:
            candidate = lib_dir / f"_zignal{extension}"
            print(f"DEBUG: Checking for library at: {candidate}", file=sys.stderr)
            if candidate.exists():
                library_path = candidate
                print(f"DEBUG: Found library: {library_path}", file=sys.stderr)
                break

        if not library_path:
            raise RuntimeError(f"Built library not found in {lib_dir}. Available files: {list(lib_dir.glob('*')) if lib_dir.exists() else 'directory does not exist'}")

        # Determine destination path
        dest_dir = Path(self.get_ext_fullpath(ext.name)).parent
        dest_dir.mkdir(parents=True, exist_ok=True)

        # Copy to the correct location with correct name
        dest_path = Path(self.get_ext_fullpath(ext.name))
        print(f"DEBUG: Copying {library_path} -> {dest_path}", file=sys.stderr)
        shutil.copy2(library_path, dest_path)
        print(f"DEBUG: Copy completed. File exists at destination: {dest_path.exists()}", file=sys.stderr)


class BinaryDistribution(Distribution):
    """Distribution which always forces a binary package with platform tag."""

    def has_ext_modules(self):
        return True


def get_zig_target():
    """Get Zig target from environment variable, defaulting to native."""
    return os.environ.get("ZIG_TARGET", "native")


def get_zig_optimize():
    """Get Zig optimization mode from environment variable, defaulting to ReleaseFast."""
    return os.environ.get("ZIG_OPTIMIZE", "ReleaseFast")


if __name__ == "__main__":
    setup(
        packages=find_packages(),
        ext_modules=[ZigExtension("zignal._zignal", get_zig_target(), get_zig_optimize())],
        cmdclass={"build_ext": ZigBuildExt},
        distclass=BinaryDistribution,
        zip_safe=False,
    )

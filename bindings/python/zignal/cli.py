import os
import subprocess
import sys
from pathlib import Path


def main():
    """Wrapper to run the native zignal CLI binary."""
    # Find the binary relative to this file
    binary_name = "zignal.exe" if sys.platform == "win32" else "zignal"
    binary_path = Path(__file__).parent / binary_name

    if not binary_path.exists():
        print(f"Error: Could not find zignal binary at {binary_path}", file=sys.stderr)
        print(
            "Please ensure the package is installed correctly or that the project has been built for development.",
            file=sys.stderr,
        )
        sys.exit(1)

    # Pass all arguments through to the binary
    args = [str(binary_path)] + sys.argv[1:]

    # Handle signals gracefully
    try:
        if sys.platform != "win32":
            os.execv(binary_path, args)
        else:
            sys.exit(subprocess.run(args).returncode)
    except KeyboardInterrupt:
        # Allow the subprocess to handle it or exit cleanly
        sys.exit(130)
    except OSError as e:
        print(f"Error executing {binary_name}: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()

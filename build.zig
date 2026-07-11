// Copyright (C) 2024 B*Factory

const std = @import("std");
const builtin = @import("builtin");
const zignal_version = std.SemanticVersion.parse(@import("build.zig.zon").version) catch unreachable;
const min_zig_version = std.SemanticVersion.parse(@import("build.zig.zon").minimum_zig_version) catch unreachable;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Option to print MD5 checksums for updating golden values
    const print_md5sums = b.option(bool, "print-md5sums", "Print MD5 checksums instead of testing them") orelse false;
    const debug_test_images = b.option(bool, "debug-test-images", "Save regression test renderings as PNGs") orelse false;

    // Export module for use as dependency
    const zignal = b.addModule("zignal", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    const version = resolveVersion(b);
    const version_options = b.addOptions();
    version_options.addOption([]const u8, "version", b.fmt("{f}", .{version}));
    zignal.addOptions("build_options", version_options);

    // Create a simple library for documentation generation
    const lib = b.addLibrary(.{
        .name = "zignal",
        .linkage = .static,
        .root_module = zignal,
    });

    // Generate documentation
    const docs_step = b.step("docs", "Generate documentation");
    const docs_install = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&docs_install.step);

    const exe = b.addExecutable(.{
        .name = "zignal",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .link_libc = target.result.os.tag == .windows,
            .imports = &.{
                .{ .name = "zignal", .module = zignal },
            },
        }),
    });
    b.installArtifact(exe);
    const run_step = b.step("run", "Run the CLI app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    // Version info step
    const version_info_step = b.step("version", "Print the resolved version information");
    const version_info_run = b.addRunArtifact(exe);
    version_info_run.addArg("version");
    version_info_step.dependOn(&version_info_run.step);

    // Check compilation
    const check = b.step("check", "Check if zignal compiles");
    check.dependOn(&lib.step);

    // Run tests
    const test_step = b.step("test", "Run library tests");
    const modules = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "color", .path = "src/color.zig" },
        .{ .name = "image", .path = "src/image.zig" },
        .{ .name = "geometry", .path = "src/geometry.zig" },
        .{ .name = "matrix", .path = "src/matrix.zig" },
        .{ .name = "perlin", .path = "src/perlin.zig" },
        .{ .name = "canvas", .path = "src/canvas.zig" },
        .{ .name = "codecs", .path = "src/codecs.zig" },
        .{ .name = "fdm", .path = "src/fdm.zig" },
        .{ .name = "pca", .path = "src/pca.zig" },
        .{ .name = "terminal", .path = "src/terminal.zig" },
        .{ .name = "font", .path = "src/font.zig" },
        .{ .name = "features", .path = "src/features.zig" },
        .{ .name = "optimization", .path = "src/optimization.zig" },
        .{ .name = "qrcode", .path = "src/qrcode.zig" },
        .{ .name = "meta", .path = "src/meta.zig" },
    };

    for (modules) |module| {
        const module_test = b.addTest(.{
            .name = module.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(module.path),
                .target = target,
                .optimize = optimize,
            }),
        });

        // Pass build options to tests
        const options = b.addOptions();
        options.addOption(bool, "print_md5sums", print_md5sums);
        options.addOption(bool, "debug_test_images", debug_test_images);
        module_test.root_module.addOptions("build_options", options);
        const module_test_run = b.addRunArtifact(module_test);
        test_step.dependOn(&module_test_run.step);
    }

    // Format check
    const fmt_step = b.step("fmt", "Check code formatting");
    const fmt = b.addFmt(.{
        .paths = b.pathList(&.{ "src", "build.zig", "build.zig.zon" }),
        .check = true,
    });
    fmt_step.dependOn(&fmt.step);

    // Set default behavior
    b.default_step.dependOn(docs_step);
    b.default_step.dependOn(fmt_step);

    // Python bindings
    const py_bindings_step = b.step("python-bindings", "Build the python bindings");
    const os_tag = target.result.os.tag;
    const py_paths: PythonPaths = .fromOptions(b);

    const py_module = b.addLibrary(.{
        .name = "zignal",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("bindings/python/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .imports = &.{.{ .name = "zignal", .module = zignal }},
        }),
    });
    linkPython(b, py_module, target, optimize, "python3", py_paths);

    const extension = switch (os_tag) {
        .windows => ".pyd",
        .macos => ".dylib",
        else => ".so",
    };

    // `python-stubs` is its own step, not a dependency of `python-bindings`, so the extension can
    // build and run tests without regenerating .pyi files.
    const python_stubs_step = b.step("python-stubs", "Generate Python type stub files (.pyi)");
    const stub_generator = b.addExecutable(.{
        .name = "python_stubs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bindings/python/src/generate_stubs.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zignal", .module = zignal }},
        }),
    });
    linkPython(b, stub_generator, target, optimize, "python3-embed", py_paths);

    const run_stub_generator = b.addRunArtifact(stub_generator);
    run_stub_generator.cwd = b.path("bindings/python/zignal");
    python_stubs_step.dependOn(&run_stub_generator.step);

    const output_name = b.fmt("lib/_zignal{s}", .{extension});
    const install_py_module = b.addInstallFile(py_module.getEmittedBin(), output_name);

    // Ensure CLI is installed to zig-out/bin so setup.py can find it
    const install_cli = b.addInstallArtifact(exe, .{});
    py_bindings_step.dependOn(&install_cli.step);

    py_bindings_step.dependOn(&install_py_module.step);

    // Also copy the built extension into the source package directory for local development
    const pkg_dir = b.pathJoin(&.{ b.root.root_dir.path.?, "bindings/python/zignal" });
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(py_module.getEmittedBin(), b.fmt("{s}/_zignal{s}", .{ pkg_dir, extension }));

    const cli_ext = if (os_tag == .windows) ".exe" else "";
    const cli_name = b.fmt("zignal{s}", .{cli_ext});
    _ = wf.addCopyFile(exe.getEmittedBin(), b.fmt("{s}/{s}", .{ pkg_dir, cli_name }));

    py_bindings_step.dependOn(&wf.step);

    // Convenience umbrella: build the extension and (re)generate stubs in one go.
    const python_step = b.step("python", "Build the Python bindings and type stubs");
    python_step.dependOn(py_bindings_step);
    python_step.dependOn(python_stubs_step);
}

const Build = blk: {
    if (builtin.zig_version.order(min_zig_version) == .lt) {
        const message = std.fmt.comptimePrint(
            \\Zig version is too old:
            \\  current Zig version: {f}
            \\  minimum Zig version: {f}
        , .{ builtin.zig_version, min_zig_version });
        @compileError(message);
    } else {
        break :blk std.Build;
    }
};

/// Returns `MAJOR.MINOR.PATCH-dev` when `git describe` fails.
fn resolveVersion(b: *std.Build) std.SemanticVersion {
    const version_string = b.option([]const u8, "version-string", "Override the version of this build");
    if (version_string) |semver_string| {
        return std.SemanticVersion.parse(semver_string) catch |err| {
            std.debug.panic("Expected -Dversion-string={s} to be a semantic version: {}", .{ semver_string, err });
        };
    }

    if (zignal_version.pre == null and zignal_version.build == null) return zignal_version;

    // On an exact tag, return the version as-is.
    if (runGit(b, &.{ "describe", "--tags", "--exact-match" }) != null) return zignal_version;

    // Otherwise build a dev version from the short hash and a commit count.
    const commit_hash = runGit(b, &.{ "rev-parse", "--short", "HEAD" }) orelse return zignal_version;
    // Count commits since the most recent base version tag (ending in .0),
    // falling back to the total commit count when no such tag exists.
    const commit_count = if (runGit(b, &.{ "describe", "--tags", "--match=*.0", "--abbrev=0" })) |base_tag|
        runGit(b, &.{ "rev-list", "--count", b.fmt("{s}..HEAD", .{base_tag}) }) orelse return zignal_version
    else
        runGit(b, &.{ "rev-list", "--count", "HEAD" }) orelse return zignal_version;

    return .{
        .major = zignal_version.major,
        .minor = zignal_version.minor,
        .patch = zignal_version.patch,
        .pre = b.fmt("dev.{s}", .{commit_count}),
        .build = commit_hash,
    };
}

/// Run a subprocess at configure time and return its trimmed stdout, or null on
/// any failure (spawn error, non-zero exit, empty output).
fn runCapture(b: *std.Build, argv: []const []const u8) ?[]const u8 {
    var code: u8 = undefined;
    const out = b.runAllowFail(argv, &code, .ignore) catch return null;
    const trimmed = std.mem.trim(u8, out, " \r\n");
    return if (trimmed.len == 0) null else trimmed;
}

/// Run `python -c <snippet>` (honoring `$PYTHON`) and return its trimmed stdout, or null on failure.
fn pythonValue(b: *std.Build, snippet: []const u8) ?[]const u8 {
    const exe = b.graph.environ_map.get("PYTHON") orelse "python";
    return runCapture(b, &.{ exe, "-c", snippet });
}

/// Run a git command in the repo root and return its trimmed stdout, or null on
/// failure (git missing, non-zero exit — e.g. not on a tag, not a repo).
fn runGit(b: *std.Build, args: []const []const u8) ?[]const u8 {
    const dir = b.root.root_dir.path orelse ".";
    var full_args: std.ArrayList([]const u8) = .empty;
    defer full_args.deinit(b.allocator);
    full_args.appendSlice(b.allocator, &.{ "git", "-C", dir }) catch return null;
    full_args.appendSlice(b.allocator, args) catch return null;
    return runCapture(b, full_args.items);
}

/// Python paths from `-D` options. setup.py passes these so the values become part of Zig's
/// configure-cache key — env vars are not, so a cached graph would silently ignore them.
const PythonPaths = struct {
    include_dir: ?[]const u8,
    libs_dir: ?[]const u8,
    lib_name: ?[]const u8,

    fn fromOptions(b: *Build) PythonPaths {
        return .{
            // Option, else autodetect from the active interpreter — resolved once here, not per linkPython call.
            .include_dir = b.option([]const u8, "python-include-dir", "Python headers dir (else autodetected)") orelse
                pythonValue(b, "import sysconfig;print(sysconfig.get_path('include'),end='')"),
            .libs_dir = b.option([]const u8, "python-libs-dir", "Python import-library dir (Windows)"),
            .lib_name = b.option([]const u8, "python-lib-name", "libpython name to link"),
        };
    }
};

/// Translate Python.h and import it as `c`, linking libpython where required (embedding executables
/// always, extension modules only on Windows). `python_lib` is the default pkg-config name
/// ("python3" / "python3-embed").
fn linkPython(
    b: *Build,
    artifact: *Build.Step.Compile,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    python_lib: []const u8,
    py: PythonPaths,
) void {
    const root = artifact.root_module;
    const os_tag = target.result.os.tag;
    const is_windows = os_tag == .windows;

    const tc = b.addTranslateC(.{
        .root_source_file = b.path("bindings/python/src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    // `py.include_dir` is the option or the autodetected interpreter include; if neither resolved,
    // fall back to pkg-config's ambient `python3` (last resort, may be a different Python).
    if (py.include_dir) |inc| {
        validatePath(inc, "python-include-dir");
        tc.addIncludePath(.{ .cwd_relative = inc });
    } else if (is_windows) {
        @panic("Could not determine the Python include directory; pass -Dpython-include-dir=.");
    } else {
        tc.linkSystemLibrary(python_lib, .{});
    }
    root.addImport("c", tc.createModule());

    root.link_libc = true;

    // Extension modules don't link libpython — symbols bind to the loading interpreter
    // (`-undefined dynamic_lookup` on Mach-O). Windows is the exception: link pythonXY.lib.
    if (artifact.isDynamicLibrary() and !is_windows) {
        artifact.linker_allow_shlib_undefined = true;
        return;
    }

    if (py.libs_dir) |dir| {
        validatePath(dir, "python-libs-dir");
        root.addLibraryPath(.{ .cwd_relative = dir });
    }

    const lib_name = if (py.lib_name) |name| blk: {
        validateLibName(name, "python-lib-name");
        // On Windows, strip the .lib extension pkg-config-style names don't carry.
        if (is_windows and std.mem.endsWith(u8, name, ".lib")) {
            break :blk name[0 .. name.len - ".lib".len];
        }
        break :blk name;
    } else python_lib;
    root.linkSystemLibrary(lib_name, .{});

    if (os_tag == .macos) root.addRPathSpecial("@loader_path");
}

fn validatePath(path: []const u8, opt_name: []const u8) void {
    if (!std.fs.path.isAbsolute(path)) {
        std.debug.panic("Invalid path in {s}: '{s}'. An absolute path is required.", .{ opt_name, path });
    }
}

fn validateLibName(name: []const u8, opt_name: []const u8) void {
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.') {
            std.debug.panic("Invalid character in {s}: '{c}'. Only alphanumeric, _, -, and . are allowed.", .{ opt_name, c });
        }
    }
}

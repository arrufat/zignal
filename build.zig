// Copyright (C) 2024 B*Factory

const std = @import("std");
const builtin = @import("builtin");
const zignal_version = std.SemanticVersion.parse(@import("build.zig.zon").version) catch unreachable;
const min_zig_version = std.SemanticVersion.parse(@import("build.zig.zon").minimum_zig_version) catch unreachable;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const print_md5sums = b.option(bool, "print-md5sums", "Print MD5 checksums instead of testing them") orelse false;
    const debug_test_images = b.option(bool, "debug-test-images", "Save regression test renderings as PNGs") orelse false;

    const zignal = b.addModule("zignal", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    const version = resolveVersion(b);
    const version_options = b.addOptions();
    version_options.addOption([]const u8, "version", b.fmt("{f}", .{version}));
    zignal.addOptions("build_options", version_options);

    const lib = b.addLibrary(.{
        .name = "zignal",
        .linkage = .static,
        .root_module = zignal,
    });

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
            .strip = optimize != .debug,
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

    const version_info_step = b.step("version", "Print the resolved version information");
    const version_info_run = b.addRunArtifact(exe);
    version_info_run.addArg("version");
    version_info_step.dependOn(&version_info_run.step);

    const check = b.step("check", "Check if zignal compiles");
    check.dependOn(&lib.step);

    const test_step = b.step("test", "Run library tests");
    const test_options = b.addOptions();
    test_options.addOption(bool, "print_md5sums", print_md5sums);
    test_options.addOption(bool, "debug_test_images", debug_test_images);

    const modules = [_][]const u8{
        "color",
        "image",
        "geometry",
        "matrix",
        "perlin",
        "canvas",
        "codecs",
        "fdm",
        "pca",
        "terminal",
        "font",
        "features",
        "optimization",
        "qrcode",
        "meta",
    };

    for (modules) |name| {
        const module_test = b.addTest(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
            }),
        });
        module_test.root_module.addOptions("build_options", test_options);
        const module_test_run = b.addRunArtifact(module_test);
        test_step.dependOn(&module_test_run.step);
    }

    const fmt_step = b.step("fmt", "Check code formatting");
    const fmt = b.addFmt(.{
        .paths = b.pathList(&.{ "src", "build.zig", "build.zig.zon" }),
        .check = true,
    });
    fmt_step.dependOn(&fmt.step);

    b.default_step.dependOn(docs_step);
    b.default_step.dependOn(fmt_step);

    const py_bindings_step = b.step("python-bindings", "Build the python bindings");
    // `python-stubs` is its own step, not a dependency of `python-bindings`, so the extension can
    // build and run tests without regenerating .pyi files.
    const python_stubs_step = b.step("python-stubs", "Generate Python type stub files (.pyi)");
    // Convenience umbrella: build the extension and (re)generate stubs in one go.
    const python_step = b.step("python", "Build the Python bindings and type stubs");
    python_step.dependOn(py_bindings_step);
    python_step.dependOn(python_stubs_step);

    const os_tag = target.result.os.tag;
    const py_paths: PythonPaths = .fromOptions(b);

    const tc = b.addTranslateC(.{
        .root_source_file = b.path("bindings/python/src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    if (py_paths.include_dir) |inc| {
        validatePath(inc, "python-include-dir");
        tc.addIncludePath(.{ .cwd_relative = inc });
    } else if (os_tag == .windows) {
        // Fail lazily so steps that don't need Python still work.
        const fail = b.addFail("Could not determine the Python include directory; pass -Dpython-include-dir=.");
        py_bindings_step.dependOn(&fail.step);
        python_stubs_step.dependOn(&fail.step);
        return;
    } else {
        // Last resort: ambient pkg-config python3 (its cflags match python3-embed's; may be a different Python).
        tc.linkSystemLibrary("python3", .{});
    }
    const c_module = tc.createModule();

    const py_module = b.addLibrary(.{
        .name = "zignal",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("bindings/python/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .debug,
            .imports = &.{
                .{ .name = "zignal", .module = zignal },
                .{ .name = "c", .module = c_module },
            },
        }),
    });
    linkPython(py_module, py_paths);

    const extension = switch (os_tag) {
        .windows => ".pyd",
        .macos => ".dylib",
        else => ".so",
    };

    const stub_generator = b.addExecutable(.{
        .name = "python_stubs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bindings/python/src/generate_stubs.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zignal", .module = zignal },
                .{ .name = "c", .module = c_module },
            },
        }),
    });
    linkPython(stub_generator, py_paths);

    const run_stub_generator = b.addRunArtifact(stub_generator);
    run_stub_generator.cwd = b.path("bindings/python/zignal");
    python_stubs_step.dependOn(&run_stub_generator.step);

    const output_name = b.fmt("lib/_zignal{s}", .{extension});
    const install_py_module = b.addInstallFile(py_module.getEmittedBin(), output_name);

    // Ensure CLI is installed to zig-out/bin so setup.py can find it
    const install_cli = b.addInstallArtifact(exe, .{});
    py_bindings_step.dependOn(&install_cli.step);
    py_bindings_step.dependOn(&install_py_module.step);

    // Also copy the built extension and CLI into the source package directory for local development
    const usf = b.addUpdateSourceFiles();
    usf.addCopyFileToSource(py_module.getEmittedBin(), b.fmt("bindings/python/zignal/_zignal{s}", .{extension}));
    usf.addCopyFileToSource(exe.getEmittedBin(), b.fmt("bindings/python/zignal/zignal{s}", .{target.result.exeFileExt()}));
    py_bindings_step.dependOn(&usf.step);
}

// Gating `build`'s parameter type keeps the version message as the only error on old compilers.
const Build = if (builtin.zig_version.order(min_zig_version) == .lt)
    @compileError(std.fmt.comptimePrint(
        \\Zig version is too old:
        \\  current Zig version: {f}
        \\  minimum Zig version: {f}
    , .{ builtin.zig_version, min_zig_version }))
else
    std.Build;

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
    const revspec = if (runGit(b, &.{ "describe", "--tags", "--match=*.0", "--abbrev=0" })) |base_tag|
        b.fmt("{s}..HEAD", .{base_tag})
    else
        "HEAD";
    const commit_count = runGit(b, &.{ "rev-list", "--count", revspec }) orelse return zignal_version;

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
    const full_args = std.mem.concat(b.allocator, []const u8, &.{ &.{ "git", "-C", dir }, args }) catch return null;
    defer b.allocator.free(full_args);
    return runCapture(b, full_args);
}

/// Python paths from `-D` options. setup.py passes these so the values become part of Zig's
/// configure-cache key — env vars are not, so a cached graph would silently ignore them.
const PythonPaths = struct {
    include_dir: ?[]const u8,
    libs_dir: ?[]const u8,
    lib_name: ?[]const u8,

    fn fromOptions(b: *std.Build) PythonPaths {
        return .{
            // Option, else autodetect from the active interpreter — resolved once here, not per linkPython call.
            .include_dir = b.option([]const u8, "python-include-dir", "Python headers dir (else autodetected)") orelse
                pythonValue(b, "import sysconfig;print(sysconfig.get_path('include'),end='')"),
            .libs_dir = b.option([]const u8, "python-libs-dir", "Python import-library dir (Windows)"),
            .lib_name = b.option([]const u8, "python-lib-name", "libpython name to link"),
        };
    }
};

/// Links libpython where required (embedding executables always, extension modules only on Windows).
fn linkPython(artifact: *std.Build.Step.Compile, py: PythonPaths) void {
    const root = artifact.root_module;
    const os_tag = root.resolved_target.?.result.os.tag;
    const is_windows = os_tag == .windows;

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

    // Default pkg-config names: extension modules bind to "python3", embedding executables to "python3-embed".
    const lib_name = if (py.lib_name) |name| blk: {
        validateLibName(name, "python-lib-name");
        // On Windows, strip the .lib extension pkg-config-style names don't carry.
        if (is_windows and std.mem.endsWith(u8, name, ".lib")) {
            break :blk name[0 .. name.len - ".lib".len];
        }
        break :blk name;
    } else if (artifact.isDynamicLibrary()) "python3" else "python3-embed";
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

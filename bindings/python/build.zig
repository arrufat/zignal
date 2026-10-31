const std = @import("std");

const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // An explicit mode keeps a bare `--release` from reaching translate-c, which declares no preferred one.
    const translate_c = b.dependency("translate_c", .{ .optimize = optimize });
    const zignal_dep = b.dependency("zignal", .{ .target = target, .optimize = optimize });
    const zignal = zignal_dep.module("zignal");
    const cli = zignal_dep.artifact("zignal");

    // `stubs` is its own step, not part of `install`, so the extension can build and run tests
    // without regenerating .pyi files.
    const install_step = b.getInstallStep();
    const stubs_step = b.step("stubs", "Generate Python type stub files (.pyi)");

    const os_tag = target.result.os.tag;
    const py_paths: PythonPaths = .fromOptions(b);

    if (py_paths.include_dir == null and os_tag == .windows) {
        // Fail lazily so `zig build -h` still works.
        const fail = b.addFail("Could not determine the Python include directory; pass -Dpython-include-dir=.");
        install_step.dependOn(&fail.step);
        stubs_step.dependOn(&fail.step);
        return;
    }
    const translator: Translator = .init(translate_c, .{
        .c_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
        // Zero-default struct fields like the old built-in translate-c (`.ob_base = .{}`).
        .default_init = true,
        // Last resort: ambient pkg-config python3 (its cflags match python3-embed's; may be a different Python).
        .link_system_libs = if (py_paths.include_dir == null) &.{.{ .name = "python3" }} else &.{},
    });
    if (py_paths.include_dir) |inc| {
        validatePath(inc, "python-include-dir");
        translator.addIncludePath(.{ .cwd_relative = inc });
    }

    const py_module = b.addLibrary(.{
        .name = "zignal",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .debug,
            .imports = &.{
                .{ .name = "zignal", .module = zignal },
                .{ .name = "c", .module = translator.mod },
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
            .root_source_file = b.path("src/generate_stubs.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zignal", .module = zignal },
                .{ .name = "c", .module = translator.mod },
            },
        }),
    });
    linkPython(stub_generator, py_paths);

    const run_stub_generator = b.addRunArtifact(stub_generator);
    run_stub_generator.cwd = b.path("zignal");
    stubs_step.dependOn(&run_stub_generator.step);

    // setup.py picks the extension and the CLI up from zig-out.
    b.getInstallStep().dependOn(&b.addInstallFile(py_module.getEmittedBin(), b.fmt("lib/_zignal{s}", .{extension})).step);
    b.installArtifact(cli);

    // Also copy the built extension and CLI into the source package directory for local development.
    const usf = b.addUpdateSourceFiles();
    usf.addCopyFileToSource(py_module.getEmittedBin(), b.fmt("zignal/_zignal{s}", .{extension}));
    usf.addCopyFileToSource(cli.getEmittedBin(), b.fmt("zignal/zignal{s}", .{target.result.exeFileExt()}));
    install_step.dependOn(&usf.step);
}

/// Run `python -c <snippet>` (honoring `$PYTHON`) and return its trimmed stdout, or null on failure.
fn pythonValue(b: *std.Build, snippet: []const u8) ?[]const u8 {
    const exe = b.graph.environ_map.get("PYTHON") orelse "python";
    var code: u8 = undefined;
    const out = b.runAllowFail(&.{ exe, "-c", snippet }, &code, .ignore) catch return null;
    const trimmed = std.mem.trim(u8, out, " \r\n");
    return if (trimmed.len == 0) null else trimmed;
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

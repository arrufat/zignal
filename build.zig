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
    const zignal = b.addModule("zignal", .{ .root_source_file = b.path("src/root.zig"), .target = target });
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

    const cli = b.addExecutable(.{
        .name = "zignal",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .link_libc = target.result.os.tag == .windows,
            .imports = &.{
                .{ .name = "zignal", .module = zignal },
            },
        }),
    });
    b.installArtifact(cli);
    const run_step = b.step("run", "Run the CLI app");
    const run_cmd = b.addRunArtifact(cli);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    // Version info step
    const version_info_step = b.step("version", "Print the resolved version information");
    const version_info_run = b.addRunArtifact(cli);
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
        .{ .name = "png", .path = "src/png.zig" },
        .{ .name = "deflate", .path = "src/compression/deflate.zig" },
        .{ .name = "zlib", .path = "src/compression/zlib.zig" },
        .{ .name = "gzip", .path = "src/compression/gzip.zig" },
        .{ .name = "fdm", .path = "src/fdm.zig" },
        .{ .name = "jpeg", .path = "src/jpeg.zig" },
        .{ .name = "pca", .path = "src/pca.zig" },
        .{ .name = "sixel", .path = "src/sixel.zig" },
        .{ .name = "kitty", .path = "src/kitty.zig" },
        .{ .name = "font", .path = "src/font.zig" },
        .{ .name = "features", .path = "src/features.zig" },
        .{ .name = "optimization", .path = "src/optimization.zig" },
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
        .paths = &.{ "src", "build.zig", "build.zig.zon" },
        .check = true,
    });
    fmt_step.dependOn(&fmt.step);

    // Set default behavior
    b.default_step.dependOn(docs_step);
    b.default_step.dependOn(fmt_step);

    // Python bindings
    const py_bindings_step = b.step("python-bindings", "Build the python bindings");
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

    // Link Python for shared library
    const target_info = target.result;
    linkPython(b, py_module, "python3", target.result);

    // Determine output file extension based on target platform
    const extension = switch (target_info.os.tag) {
        .windows => ".pyd",
        .macos => ".dylib",
        else => ".so",
    };

    // Python type stub generation
    const python_stubs_step = b.step("python-stubs", "Generate Python type stub files (.pyi)");
    const stub_generator = b.addExecutable(.{
        .name = "python_stubs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bindings/python/src/generate_stubs.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{.{ .name = "zignal", .module = zignal }},
        }),
    });

    // Link Python for executable
    linkPython(b, stub_generator, "python3-embed", target_info);

    // Run stub generator in the python bindings directory
    const run_stub_generator = b.addRunArtifact(stub_generator);
    run_stub_generator.cwd = b.path("bindings/python/zignal");
    python_stubs_step.dependOn(&run_stub_generator.step);

    const output_name = b.fmt("lib/_zignal{s}", .{extension});
    const install_py_module = b.addInstallFile(py_module.getEmittedBin(), output_name);

    // Ensure CLI is installed to zig-out/bin so setup.py can find it
    const install_cli = b.addInstallArtifact(cli, .{});
    py_bindings_step.dependOn(&install_cli.step);

    // Make python-bindings depend on stub generation so stubs are always up to date
    py_bindings_step.dependOn(&run_stub_generator.step);
    py_bindings_step.dependOn(&install_py_module.step);

    // Also copy the built extension into the source package directory for local development
    const pkg_dir = b.pathJoin(&.{ b.build_root.path.?, "bindings/python/zignal" });
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(py_module.getEmittedBin(), b.fmt("{s}/_zignal{s}", .{ pkg_dir, extension }));

    // Copy CLI tool to python package
    const cli_ext = if (target_info.os.tag == .windows) ".exe" else "";
    const cli_name = b.fmt("zignal{s}", .{cli_ext});
    _ = wf.addCopyFile(cli.getEmittedBin(), b.fmt("{s}/{s}", .{ pkg_dir, cli_name }));

    py_bindings_step.dependOn(&wf.step);
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
    // Check if we're exactly on a tagged release
    _ = runGit(b, &.{ "describe", "--tags", "--exact-match" }) catch {
        // Not on a tag, need to create a dev version
        const git_hash_raw = runGit(b, &.{ "rev-parse", "--short", "HEAD" }) catch return zignal_version;
        const commit_hash = std.mem.trim(u8, git_hash_raw, " \n\r");
        // Get the commit count - either from base tag or total
        const commit_count = blk: {
            // Try to find the most recent base version tag (ending with .0)
            const base_tag_raw = runGit(b, &.{ "describe", "--tags", "--match=*.0", "--abbrev=0" }) catch {
                // No .0 tags found, fall back to total commit count
                const git_count_raw = runGit(b, &.{ "rev-list", "--count", "HEAD" }) catch return zignal_version;
                break :blk std.mem.trim(u8, git_count_raw, " \n\r");
            };

            const base_tag = std.mem.trim(u8, base_tag_raw, " \n\r");
            // Count commits since the base tag
            const count_cmd = b.fmt("{s}..HEAD", .{base_tag});
            const git_count_raw = runGit(b, &.{ "rev-list", "--count", count_cmd }) catch return zignal_version;
            break :blk std.mem.trim(u8, git_count_raw, " \n\r");
        };

        return .{
            .major = zignal_version.major,
            .minor = zignal_version.minor,
            .patch = zignal_version.patch,
            .pre = b.fmt("dev.{s}", .{commit_count}),
            .build = commit_hash,
        };
    };
    // We're exactly on a tag, return the version as-is
    return zignal_version;
}

/// Helper function to run git commands and return stdout
fn runGit(b: *std.Build, args: []const []const u8) ![]const u8 {
    var code: u8 = undefined;
    const dir = b.pathFromRoot(".");
    var full_args: std.ArrayList([]const u8) = .empty;
    defer full_args.deinit(b.allocator);
    try full_args.appendSlice(b.allocator, &.{ "git", "-C", dir });
    try full_args.appendSlice(b.allocator, args);
    return b.runAllowFail(full_args.items, &code, .ignore);
}

/// Helper function to link Python to an artifact
/// @param artifact: The build artifact (library or executable) to link Python to
/// @param python_lib: The Python library name ("python3" for shared libs, "python3-embed" for executables)
/// @param target_info: Target platform information for platform-specific linking
fn linkPython(b: *Build, artifact: *Build.Step.Compile, python_lib: []const u8, target_info: std.Target) void {
    const os_tag = target_info.os.tag;
    artifact.root_module.link_libc = true;
    if (b.graph.environ_map.get("PYTHON_INCLUDE_DIR")) |python_include| {
        validatePath(python_include, "PYTHON_INCLUDE_DIR");
        artifact.root_module.addIncludePath(.{ .cwd_relative = python_include });
    }

    // Common logic to add library path if provided
    if (b.graph.environ_map.get("PYTHON_LIBS_DIR")) |libs_dir| {
        validatePath(libs_dir, "PYTHON_LIBS_DIR");
        artifact.root_module.addLibraryPath(.{ .cwd_relative = libs_dir });
    }

    // Determine the library name to link against
    const lib_name_to_link = if (b.graph.environ_map.get("PYTHON_LIB_NAME")) |lib_name| blk: {
        validateLibName(lib_name, "PYTHON_LIB_NAME");
        // On Windows, strip the .lib extension
        if (os_tag == .windows and std.mem.endsWith(u8, lib_name, ".lib")) {
            break :blk lib_name[0 .. lib_name.len - 4];
        }
        break :blk lib_name;
    } else python_lib;

    artifact.root_module.linkSystemLibrary(lib_name_to_link, .{});
    if (os_tag == .macos) {
        artifact.root_module.addRPathSpecial("@loader_path");
    }
}

fn validatePath(path: []const u8, env_name: []const u8) void {
    if (std.mem.indexOf(u8, path, "..") != null) {
        std.debug.panic("Invalid path in {s}: '{s}'. Path traversal is not allowed.", .{ env_name, path });
    }
}

fn validateLibName(name: []const u8, env_name: []const u8) void {
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.') {
            std.debug.panic("Invalid character in {s}: '{c}'. Only alphanumeric, _, -, and . are allowed.", .{ env_name, c });
        }
    }
}

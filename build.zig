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

    // Export module for use as dependency
    _ = b.addModule("zignal", .{ .root_source_file = b.path("src/root.zig") });

    // Create a simple library for documentation generation
    const lib = b.addLibrary(.{
        .name = "zignal",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Generate documentation
    const docs_step = b.step("docs", "Generate documentation");
    const docs_install = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&docs_install.step);

    // Check compilation
    const check = b.step("check", "Check if zignal compiles");
    check.dependOn(&lib.step);

    // Run tests
    const test_step = b.step("test", "Run library tests");
    for ([_][]const u8{
        "color",  "image", "geometry", "matrix", "svd",  "perlin",
        "canvas", "png",   "deflate",  "fdm",    "jpeg", "pca",
        "sixel",  "kitty", "font",
    }) |module| {
        const module_test = b.addTest(.{
            .name = module,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/{s}.zig", .{module})),
                .target = target,
                .optimize = optimize,
            }),
        });

        // Pass build options to tests
        const options = b.addOptions();
        options.addOption(bool, "print_md5sums", print_md5sums);
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

    // Version info step
    const version_info_step = b.step("version", "Print the resolved version information");
    const version_info_exe = b.addExecutable(.{
        .name = "version",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/version.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });

    // Add build options to version info executable
    const version_options = b.addOptions();
    // Resolve version once to avoid duplicate option declarations
    const version = resolveVersion(b);
    version_options.addOption([]const u8, "version", b.fmt("{f}", .{version}));
    version_info_exe.root_module.addOptions("build_options", version_options);

    const version_info_run = b.addRunArtifact(version_info_exe);
    version_info_step.dependOn(&version_info_run.step);

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
        }),
    });

    // Link against libc for Python headers
    py_module.linkLibC();

    // Add Python include directory if provided via environment variable
    if (std.process.getEnvVarOwned(b.allocator, "PYTHON_INCLUDE_DIR")) |python_include| {
        py_module.addIncludePath(.{ .cwd_relative = python_include });
    } else |_| {
        // No Python include directory specified - will rely on system default paths
    }

    // Add zignal module as dependency
    py_module.root_module.addImport("zignal", b.addModule("zignal", .{
        .root_source_file = b.path("src/root.zig"),
    }));

    // Add build options to python bindings
    const py_options = b.addOptions();
    py_options.addOption([]const u8, "version", b.fmt("{f}", .{version}));
    py_module.root_module.addOptions("build_options", py_options);

    // Add platform-specific python libraries and flags
    const target_info = target.result;
    switch (target_info.os.tag) {
        .windows => {
            // On Windows, link against the Python library
            if (std.process.getEnvVarOwned(b.allocator, "PYTHON_LIBS_DIR")) |libs_dir| {
                py_module.addLibraryPath(.{ .cwd_relative = libs_dir });

                if (std.process.getEnvVarOwned(b.allocator, "PYTHON_LIB_NAME")) |lib_name| {
                    // Remove the .lib extension for linkSystemLibrary
                    const lib_name_no_ext = if (std.mem.endsWith(u8, lib_name, ".lib"))
                        lib_name[0 .. lib_name.len - 4]
                    else
                        lib_name;
                    py_module.linkSystemLibrary(lib_name_no_ext);
                } else |_| {
                    // Fallback - try to link against a common Python library name
                    py_module.linkSystemLibrary("python3");
                }
            } else |_| {
                // No Python library path provided - try system default
                py_module.linkSystemLibrary("python3");
            }
        },
        .macos => {
            // On macOS, try to link against specific Python library if provided
            if (std.process.getEnvVarOwned(b.allocator, "PYTHON_LIBS_DIR")) |libs_dir| {
                py_module.addLibraryPath(.{ .cwd_relative = libs_dir });

                if (std.process.getEnvVarOwned(b.allocator, "PYTHON_LIB_NAME")) |lib_name| {
                    py_module.linkSystemLibrary(lib_name);
                } else |_| {
                    // Fallback to default
                    py_module.linkSystemLibrary("python3");
                }
            } else |_| {
                // No specific Python library path - use system default
                py_module.linkSystemLibrary("python3");
            }
        },
        .linux => {
            py_module.linkSystemLibrary("python3");
        },
        else => {
            // Try the default for other platforms
            py_module.linkSystemLibrary("python3");
        },
    }

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
        }),
    });

    // Add zignal module as dependency for stub generator
    stub_generator.root_module.addImport("zignal", b.addModule("zignal", .{
        .root_source_file = b.path("src/root.zig"),
    }));

    // Run stub generator in the python bindings directory
    const run_stub_generator = b.addRunArtifact(stub_generator);
    run_stub_generator.cwd = b.path("bindings/python/zignal");
    python_stubs_step.dependOn(&run_stub_generator.step);

    const output_name = b.fmt("lib/_zignal{s}", .{extension});
    const install_py_module = b.addInstallFile(py_module.getEmittedBin(), output_name);

    // Make python-bindings depend on stub generation so stubs are always up to date
    py_bindings_step.dependOn(&run_stub_generator.step);
    py_bindings_step.dependOn(&install_py_module.step);
}

const Build = blk: {
    if (builtin.zig_version.order(min_zig_version) == .lt) {
        const message = std.fmt.comptimePrint(
            \\Zig version is too old:
            \\  current Zig version: {}
            \\  minimum Zig version: {}
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

    const zignal_dir = b.pathFromRoot(".");

    var code: u8 = undefined;
    const git_hash_raw = b.runAllowFail(&.{ "git", "-C", zignal_dir, "rev-parse", "--short", "HEAD" }, &code, .Ignore) catch return zignal_version;
    const commit_hash = std.mem.trim(u8, git_hash_raw, " \n\r");
    const git_branch_raw = b.runAllowFail(&.{ "git", "-C", zignal_dir, "branch", "--show-current" }, &code, .Ignore) catch return zignal_version;
    const git_branch = std.mem.trim(u8, git_branch_raw, " \n\r");

    // For non-master branches, always use total commit count
    const is_master = std.mem.eql(u8, git_branch, "master");
    if (!is_master) {
        const git_count_raw = b.runAllowFail(&.{ "git", "-C", zignal_dir, "rev-list", "--count", "HEAD" }, &code, .Ignore) catch return zignal_version;
        const commit_count = std.mem.trim(u8, git_count_raw, " \n\r");
        const dev_prefix = if (git_branch.len > 0) git_branch else "dev";
        return .{
            .major = zignal_version.major,
            .minor = zignal_version.minor,
            .patch = zignal_version.patch,
            .pre = b.fmt("{s}.{s}", .{ dev_prefix, commit_count }),
            .build = commit_hash,
        };
    }

    // For master branch, use git describe
    const git_describe_raw = b.runAllowFail(&.{ "git", "-C", zignal_dir, "describe", "--tags" }, &code, .Ignore) catch {
        // If git describe fails (no tags), try to get commit count from git log
        const git_count_raw = b.runAllowFail(&.{ "git", "-C", zignal_dir, "rev-list", "--count", "HEAD" }, &code, .Ignore) catch return zignal_version;
        const commit_count = std.mem.trim(u8, git_count_raw, " \n\r");
        return .{
            .major = zignal_version.major,
            .minor = zignal_version.minor,
            .patch = zignal_version.patch,
            .pre = b.fmt("dev.{s}", .{commit_count}),
            .build = commit_hash,
        };
    };
    const git_describe = std.mem.trim(u8, git_describe_raw, " \n\r");

    switch (std.mem.count(u8, git_describe, "-")) {
        0 => {
            // Tagged release version (e.g. 0.1.0).
            std.debug.assert(std.mem.eql(u8, git_describe, b.fmt("{f}", .{zignal_version})));
            return zignal_version;
        },
        2 => {
            // Untagged development build (e.g. 2.0.1-57-g9b7de08de).
            var it = std.mem.splitScalar(u8, git_describe, '-');
            const previous_tag = it.first();
            const commit_count = it.next().?;
            const commit_ghash = it.next().?;

            const previous_version = std.SemanticVersion.parse(previous_tag) catch unreachable;

            // zignal_version must be greater than its previous version.
            if (zignal_version.order(previous_version) != .gt) {
                std.log.err("Zignal version {f} must be newer than {f}", .{
                    zignal_version,
                    previous_version,
                });
                std.process.exit(1);
            }
            std.debug.assert(std.mem.startsWith(u8, commit_ghash, "g"));

            return .{
                .major = zignal_version.major,
                .minor = zignal_version.minor,
                .patch = zignal_version.patch,
                .pre = b.fmt("dev.{s}", .{commit_count}),
                .build = commit_ghash[1..],
            };
        },
        else => {
            std.debug.print("Unexpected 'git describe' output: '{s}'\n", .{git_describe});
            std.process.exit(1);
        },
    }
}

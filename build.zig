// Copyright (C) 2024 B*Factory

const std = @import("std");
const builtin = @import("builtin");
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
        "color",
        "image",
        "geometry",
        "matrix",
        "svd",
        "perlin",
        "canvas",
        "png",
        "deflate",
        "fdm",
        "jpeg",
        "pca",
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

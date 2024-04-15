// Copyright (C) 2024 B*Factory
// License: Boost Software License

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Export module.
    _ = b.addModule("zignal", .{ .root_source_file = .{ .path = "src/zignal.zig" } });

    _ = buildModule(b, "zignal", target, optimize);

    const test_step = b.step("test", "Run library tests");
    for ([_][]const u8{
        "color",
        "matrix",
        "svd",
    }) |module| {
        const module_test = b.addTest(.{
            .name = module,
            .root_source_file = .{ .path = b.fmt("src/{s}.zig", .{module}) },
            .target = target,
            .optimize = optimize,
        });
        const module_test_run = b.addRunArtifact(module_test);
        test_step.dependOn(&module_test_run.step);
    }

    const fmt_step = b.step("fmt", "Run zig fmt");
    const fmt = b.addFmt(.{
        .paths = &.{ "src", "build.zig" },
        .check = true,
    });
    fmt_step.dependOn(&fmt.step);
    b.default_step.dependOn(fmt_step);
}

fn buildModule(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    var module: *std.Build.Step.Compile = undefined;

    if (target.result.isWasm()) {
        module = b.addExecutable(.{
            .name = name,
            .root_source_file = .{ .path = b.fmt("src/{s}.zig", .{name}) },
            .optimize = optimize,
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
                .cpu_features_add = std.Target.wasm.featureSet(&.{
                    .atomics,
                    .bulk_memory,
                    // .extended_const, not supported by Safari
                    .multivalue,
                    .mutable_globals,
                    .nontrapping_fptoint,
                    .reference_types,
                    //.relaxed_simd, not supported by Firefox or Safari
                    .sign_ext,
                    .simd128,
                    // .tail_call, not supported by Safari
                }),
            }),
        });
        module.entry = .disabled;
        module.use_llvm = true;
        module.use_lld = true;
        // Install files in the .prefix (zig-out) directory
        b.getInstallStep().dependOn(
            &b.addInstallFile(
                module.getEmittedBin(),
                b.fmt("{s}.wasm", .{name}),
            ).step,
        );
        b.installDirectory(.{
            .source_dir = .{ .path = "examples" },
            .install_dir = .prefix,
            .install_subdir = "",
        });
    } else {
        module = b.addSharedLibrary(.{
            .name = name,
            .root_source_file = .{ .path = b.fmt("src/{s}.zig", .{name}) },
            .target = target,
            .optimize = optimize,
        });
        module.root_module.strip = optimize != .Debug and target.result.os.tag != .windows;
        b.installArtifact(module);
    }
    module.rdynamic = true;
    return module;
}

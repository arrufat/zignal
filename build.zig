// Copyright (C) 2024 B*Factory
// License: Boost Software License

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Export module.
    _ = b.addModule("zignal", .{ .root_source_file = .{ .path = "src/zignal.zig" } });

    _ = buildModule(b, "zignal", target, optimize);

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/tests.zig" },
        .target = target,
        .optimize = optimize,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
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
            .source_dir = .{ .path = "lib" },
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

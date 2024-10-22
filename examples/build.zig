const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = buildModule(b, "colorspace", target, optimize);
    _ = buildModule(b, "face_alignment", target, optimize);
    _ = buildModule(b, "perlin", target, optimize);

    const fmt_step = b.step("fmt", "Run zig fmt");
    const fmt = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "build.zig.zon" },
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
    const zignal = b.dependency("zignal", .{ .target = target, .optimize = optimize });
    var module: *std.Build.Step.Compile = undefined;

    if (target.result.isWasm()) {
        module = b.addExecutable(.{
            .name = name,
            .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})),
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
            .source_dir = b.path("lib"),
            .install_dir = .prefix,
            .install_subdir = "",
        });
    } else {
        module = b.addSharedLibrary(.{
            .name = name,
            .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
        });
        module.root_module.strip = optimize != .Debug and target.result.os.tag != .windows;
        b.installArtifact(module);
    }
    module.rdynamic = true;
    module.root_module.addImport("zignal", zignal.module("zignal"));
    return module;
}

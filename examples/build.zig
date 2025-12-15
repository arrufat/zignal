const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const target_query = target.query;
    const is_wasm = target_query.cpu_arch == .wasm32 and target_query.os_tag == .freestanding;
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = if (is_wasm) .ReleaseSmall else .ReleaseFast });
    const zignal = b.dependency("zignal", .{ .target = target, .optimize = optimize });

    // List of WASM examples to build
    const wasm_examples = [_][]const u8{
        "colorspaces",
        "face_alignment",
        "perlin_noise",
        "seam_carving",
        "whitebalance",
        "fdm",
        "feature_matching",
        "metrics",
        "contrast_enhancement",
    };

    // List of additional examples to build as executables
    const exec_examples = [_][]const u8{
        "pca_example",
        "make_logo",
        "image_demo",
        "motion_blur_demo",
        "edge_detection",
        "blur_box_vs_gaussian",
    };

    // Build exec_examples with run steps and check compilation
    const check = b.step("check", "Check if examples compile");
    const run_all_step = b.step("run-all", "Run all executable examples");

    // Build all WASM examples and add to check step
    for (wasm_examples) |example_name| {
        const module = buildWasm(b, example_name, optimize, zignal);
        check.dependOn(&module.step);
    }

    // Build exec_examples once and create all steps (skip for WASM freestanding)
    if (!is_wasm) {
        for (exec_examples) |example_name| {
            const exe = b.addExecutable(.{
                .name = example_name,
                .root_module = b.createModule(.{
                    .root_source_file = b.path(b.fmt("src/{s}.zig", .{example_name})),
                    .target = target,
                    .optimize = optimize,
                }),
            });
            exe.root_module.addImport("zignal", zignal.module("zignal"));
            b.installArtifact(exe);

            // Add to check step
            check.dependOn(&exe.step);

            // Create individual run step
            const run_exe = b.addRunArtifact(exe);
            if (b.args) |args| run_exe.addArgs(args);

            // Replace underscores with hyphens for step name
            const run_name = blk: {
                var buffer: [256]u8 = undefined;
                const len = @min(example_name.len, buffer.len);
                @memcpy(buffer[0..len], example_name[0..len]);
                std.mem.replaceScalar(u8, buffer[0..len], '_', '-');
                break :blk buffer[0..len];
            };

            const run_step_name = b.fmt("run-{s}", .{run_name});
            const run_step_desc = b.fmt("Run {s} example", .{example_name});
            const individual_run_step = b.step(run_step_name, run_step_desc);
            individual_run_step.dependOn(&run_exe.step);

            // Add to run-all step
            run_all_step.dependOn(&run_exe.step);
        }
    }

    const fmt_step = b.step("fmt", "Run zig fmt");
    const fmt = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "build.zig.zon" },
        .check = true,
    });
    fmt_step.dependOn(&fmt.step);
    b.default_step.dependOn(fmt_step);
}

fn buildWasm(
    b: *std.Build,
    name: []const u8,
    optimize: std.builtin.OptimizeMode,
    zignal: *std.Build.Dependency,
) *std.Build.Step.Compile {
    const module = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
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
        }),
    });
    module.entry = .disabled;
    module.use_llvm = true;
    module.use_lld = true;
    module.rdynamic = true;

    // Set initial memory to 256MB (4096 pages) and max to 4GB for FDM operations
    module.export_memory = true;
    module.import_memory = false;
    module.initial_memory = 256 * 1024 * 1024; // 256 MB
    module.max_memory = 4 * 1024 * 1024 * 1024; // 4 GB

    // Install files in the .prefix (zig-out) directory
    b.getInstallStep().dependOn(
        &b.addInstallFile(
            module.getEmittedBin(),
            b.fmt("{s}.wasm", .{name}),
        ).step,
    );
    b.installDirectory(.{
        .source_dir = b.path("web"),
        .install_dir = .prefix,
        .install_subdir = "",
    });

    module.root_module.addImport("zignal", zignal.module("zignal"));

    return module;
}

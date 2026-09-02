const std = @import("std");
const builtin = @import("builtin");

const zignal_version = std.SemanticVersion.parse(@import("build.zig.zon").version) catch unreachable;
const min_zig_version = std.SemanticVersion.parse(@import("build.zig.zon").minimum_zig_version) catch unreachable;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const print_md5sums = b.option(bool, "print-md5sums", "Print MD5 checksums instead of testing them") orelse false;
    const debug_test_images = b.option(bool, "debug-test-images", "Save regression test renderings as PNGs") orelse false;
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &.{};
    const gpu = b.option(bool, "gpu", "Build the SPIR-V compute kernels and the Vulkan device (default: on except for freestanding targets)") orelse
        (target.result.os.tag != .freestanding);
    const cli_libc = b.option(bool, "libc", "Link the CLI against libc, which enables JPEG XL and WebP through the system libraries (default: Windows only)") orelse
        (target.result.os.tag == .windows);

    const zignal = b.addModule("zignal", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    const version = resolveVersion(b);
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", b.fmt("{f}", .{version}));
    build_options.addOption(bool, "print_md5sums", print_md5sums);
    build_options.addOption(bool, "debug_test_images", debug_test_images);
    build_options.addOption(bool, "gpu", gpu);
    zignal.addOptions("build_options", build_options);
    // Kernels are cross-compiled to SPIR-V and embedded; `Device` reads them with `@embedFile`.
    const gemm_kernel: ?*Build.Step.Compile = if (gpu) addSpirvKernel(b, "gemm") else null;
    if (gemm_kernel) |kernel| zignal.addAnonymousImport("gemm.spv", .{ .root_source_file = kernel.getEmittedBin() });

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
            .link_libc = cli_libc,
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

    // One binary: tests come from every file reachable from the root, so per-module binaries
    // would each re-run the whole image/codecs/terminal closure.
    const test_step = b.step("test", "Run library tests");
    const lib_test = b.addTest(.{
        .name = "zignal",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
    });
    lib_test.root_module.addOptions("build_options", build_options);
    if (gemm_kernel) |kernel| lib_test.root_module.addAnonymousImport("gemm.spv", .{ .root_source_file = kernel.getEmittedBin() });
    // libc lets the tests load libjxl, libwebp and the Vulkan loader (src/dynlib.zig).
    lib_test.root_module.link_libc = !target.result.cpu.arch.isWasm() and target.result.os.tag != .windows;
    test_step.dependOn(&b.addRunArtifact(lib_test).step);

    const fmt_step = b.step("fmt", "Check code formatting");
    const fmt = b.addFmt(.{
        .paths = b.pathList(&.{ "src", "build.zig", "build.zig.zon" }),
        .check = true,
    });
    fmt_step.dependOn(&fmt.step);

    b.default_step.dependOn(docs_step);
    b.default_step.dependOn(fmt_step);

    // The bindings are their own package (bindings/python) so only they pull in translate-c.
    const python_step = b.step("python", "Build the Python bindings and type stubs");
    const python_build = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "install", "stubs" });
    python_build.setCwd(b.path("bindings/python"));
    python_build.addArg(b.fmt("-Doptimize={t}", .{optimize}));
    if (!target.query.isNative()) {
        python_build.addArg(b.fmt("-Dtarget={s}", .{target.query.zigTriple(b.allocator) catch @panic("OOM")}));
        python_build.addArg(b.fmt("-Dcpu={s}", .{target.query.serializeCpuAlloc(b.allocator) catch @panic("OOM")}));
    }
    for ([_][]const u8{ "python-include-dir", "python-libs-dir", "python-lib-name" }) |name| {
        const value = b.option([]const u8, name, "Forwarded to the Python bindings build") orelse continue;
        python_build.addArg(b.fmt("-D{s}={s}", .{ name, value }));
    }
    python_step.dependOn(&python_build.step);
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

/// Compiles `src/gpu/kernels/<name>.zig` to a Vulkan 1.2 SPIR-V module.
fn addSpirvKernel(b: *std.Build, name: []const u8) *std.Build.Step.Compile {
    const kernel = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/gpu/kernels/{s}.zig", .{name})),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .spirv64,
                .os_tag = .vulkan,
                .cpu_model = .{ .explicit = &std.Target.spirv.cpu.vulkan_v1_2 },
            }),
            .optimize = .ReleaseFast,
        }),
        // SPIR-V is only supported by the self-hosted backend.
        .use_llvm = false,
        .use_lld = false,
    });
    kernel.entry = .disabled;
    return kernel;
}

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

/// Run a git command in the repo root and return its trimmed stdout, or null on
/// failure (git missing, non-zero exit — e.g. not on a tag, not a repo).
fn runGit(b: *std.Build, args: []const []const u8) ?[]const u8 {
    const dir = b.root.root_dir.path orelse ".";
    const full_args = std.mem.concat(b.allocator, []const u8, &.{ &.{ "git", "-C", dir }, args }) catch return null;
    defer b.allocator.free(full_args);
    return runCapture(b, full_args);
}

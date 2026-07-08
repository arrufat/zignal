const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");
const qrcode = zignal.qrcode;

const args = @import("args.zig");
const common = @import("common.zig");

const Args = struct {
    ec_level: ?[]const u8 = null,
    symbol_version: ?u8 = null,
    module_size: ?u32 = null,
    quiet_zone: ?u32 = null,
    output: ?[]const u8 = null,

    pub const meta = .{
        .ec_level = .{ .help = "Error correction level (l, m, q, h; default m)", .metavar = "level" },
        .symbol_version = .{ .help = "Force the QR version 1-40 (default: smallest that fits)", .metavar = "1-40" },
        .module_size = .{ .help = "Pixels per module when saving an image (default 8)", .metavar = "pixels" },
        .quiet_zone = .{ .help = "Light border around the symbol in modules (default 4)", .metavar = "modules" },
        .output = .{ .help = "Save the encoded QR as an image instead of printing it", .metavar = "path" },
    };
};

pub const description = "Encode text as a QR code or decode QR codes from images.";

pub const help = args.generateHelp(
    Args,
    "zignal qr encode [options] <text>\n       zignal qr decode <image> [image...]",
    description,
);

pub fn run(io: Io, writer: *Io.Writer, gpa: Allocator, iterator: *std.process.Args.Iterator) !void {
    const parsed = try args.parse(Args, gpa, iterator);
    defer parsed.deinit(gpa);

    if (parsed.help or parsed.positionals.len == 0) {
        try args.printHelp(writer, help);
        return;
    }

    const subcommand = parsed.positionals[0];
    const rest = parsed.positionals[1..];
    if (std.mem.eql(u8, subcommand, "encode")) {
        try encode(io, writer, gpa, rest, parsed.options);
    } else if (std.mem.eql(u8, subcommand, "decode")) {
        try decode(io, writer, gpa, rest);
    } else {
        std.log.err("unknown subcommand '{s}': expected 'encode' or 'decode'", .{subcommand});
        return error.InvalidArguments;
    }
}

fn parseEcLevel(name: ?[]const u8) !qrcode.EcLevel {
    const value = name orelse return .medium;
    if (value.len == 1) {
        return switch (std.ascii.toLower(value[0])) {
            'l' => .low,
            'm' => .medium,
            'q' => .quartile,
            'h' => .high,
            else => error.InvalidArguments,
        };
    }
    return common.parseEnum(qrcode.EcLevel, value) orelse {
        std.log.err("invalid --ec-level '{s}': expected l, m, q or h", .{value});
        return error.InvalidArguments;
    };
}

fn encode(io: Io, writer: *Io.Writer, gpa: Allocator, positionals: []const []const u8, options: Args) !void {
    if (positionals.len != 1) {
        std.log.err("encode expects exactly one text argument", .{});
        return error.InvalidArguments;
    }
    const to_file = options.output != null;
    var image = try qrcode.encodeImage(gpa, positionals[0], .{
        .ec_level = try parseEcLevel(options.ec_level),
        .version = options.symbol_version,
        // In the terminal, one pixel per module maps to one character cell.
        .module_size = if (to_file) options.module_size orelse 8 else 1,
        .quiet_zone = options.quiet_zone orelse 4,
    });
    defer image.deinit(gpa);

    if (options.output) |path| {
        try image.save(io, gpa, path);
        std.log.info("saved {d}x{d} QR code to {s}", .{ image.rows, image.cols, path });
    } else {
        try writer.print("{f}\n", .{image.display(io, .{ .sgr = .default })});
        try writer.flush();
    }
}

fn decode(io: Io, writer: *Io.Writer, gpa: Allocator, positionals: []const []const u8) !void {
    if (positionals.len == 0) {
        std.log.err("decode expects at least one image argument", .{});
        return error.InvalidArguments;
    }
    const is_batch = positionals.len > 1;
    var failures: usize = 0;
    for (positionals) |path| {
        decodeImage(io, writer, gpa, path, is_batch) catch |err| {
            std.log.err("failed to decode '{s}': {t}", .{ path, err });
            failures += 1;
        };
    }
    try writer.flush();
    if (failures > 0) return error.DecodeFailed;
}

fn decodeImage(io: Io, writer: *Io.Writer, gpa: Allocator, path: []const u8, is_batch: bool) !void {
    var image: zignal.Image(zignal.Rgba(u8)) = try .load(io, gpa, path);
    defer image.deinit(gpa);
    var gray = try image.convert(gpa, u8);
    defer gray.deinit(gpa);

    var result = (try qrcode.decode(gpa, gray)) orelse return error.NoQrCodeFound;
    defer result.deinit(gpa);
    std.log.info("{s}: version {d}, level {t}, {d} corrected codewords", .{
        path, result.version, result.ec_level, result.corrected_errors,
    });
    if (is_batch) {
        try writer.print("{s}: {s}\n", .{ path, result.data });
    } else {
        try writer.print("{s}\n", .{result.data});
    }
}

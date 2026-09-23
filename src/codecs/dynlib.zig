//! Codecs backed by a system library opened at runtime (libjxl, libwebp). They are on whenever
//! the compilation links libc, and a missing library only fails that codec's calls.

const std = @import("std");
const builtin = @import("builtin");

const meta = @import("../meta.zig");

/// `std.DynLib` needs libc to load distro libraries on Linux and has no Windows backend.
/// `link_libc` is compilation-wide, so a program that links libc turns this on.
pub const supported = builtin.link_libc and !builtin.cpu.arch.isWasm() and builtin.os.tag != .windows;

/// `file` as installed by the system, then by Homebrew on Apple silicon and Intel.
pub fn macosNames(comptime file: []const u8) []const []const u8 {
    return &.{ file, "/opt/homebrew/lib/" ++ file, "/usr/local/lib/" ++ file };
}

/// Loads the first of `names` that opens and resolves every field of `Api`, a struct of
/// function pointers named after the exported symbols. The library stays loaded for the life
/// of the process.
pub fn Library(comptime Api: type, comptime names: []const []const u8) type {
    return struct {
        var loaded: std.atomic.Value(?*const Api) = .init(null);

        /// Racing first calls both load it and the loser drops its copy (`dlopen` is
        /// reference counted).
        pub fn get() error{CodecUnavailable}!*const Api {
            if (loaded.load(.acquire)) |ptr| return ptr;
            const table = std.heap.page_allocator.create(Api) catch return error.CodecUnavailable;
            errdefer std.heap.page_allocator.destroy(table);
            var lib = for (names) |name| {
                var lib = std.DynLib.open(name) catch continue;
                if (resolve(&lib, table)) break lib;
                lib.close();
            } else return error.CodecUnavailable;
            if (loaded.cmpxchgStrong(null, table, .acq_rel, .acquire)) |winner| {
                std.heap.page_allocator.destroy(table);
                lib.close();
                return winner.?;
            }
            return table;
        }

        fn resolve(lib: *std.DynLib, table: *Api) bool {
            inline for (comptime meta.structFields(Api)) |field| {
                @field(table, field.name) = lib.lookup(field.type, field.name) orelse return false;
            }
            return true;
        }
    };
}

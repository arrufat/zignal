//! System libraries opened at runtime (libjxl, libwebp). They are on whenever the compilation
//! links libc, and a missing library only fails the calls that need it.

const std = @import("std");
const builtin = @import("builtin");

const meta = @import("meta.zig");

/// `std.DynLib` needs libc to load distro libraries on Linux and has no Windows backend.
/// `link_libc` is compilation-wide, so a program that links libc turns this on.
pub const supported = builtin.link_libc and !builtin.cpu.arch.isWasm() and builtin.os.tag != .windows;

/// `file` as installed by the system, then by Homebrew on Apple silicon and Intel.
pub fn macosNames(comptime file: []const u8) []const []const u8 {
    return &.{ file, "/opt/homebrew/lib/" ++ file, "/usr/local/lib/" ++ file };
}

/// Loads the first of `names` that opens and resolves every field of `Api`, a struct of
/// function pointers named after the exported symbols; `unavailable` is the error returned
/// when none does. The outcome, success or not, is kept for the life of the process.
pub fn Library(comptime Api: type, comptime names: []const []const u8, comptime unavailable: anytype) type {
    return struct {
        const State = enum(u8) { unloaded, loading, loaded, missing };
        var state: std.atomic.Value(State) = .init(.unloaded);
        var api: Api = undefined;

        pub fn get() @TypeOf(unavailable)!*const Api {
            while (true) switch (state.load(.acquire)) {
                .loaded => return &api,
                .missing => return unavailable,
                .unloaded => if (state.cmpxchgStrong(.unloaded, .loading, .acquire, .monotonic) == null) {
                    state.store(if (load()) .loaded else .missing, .release);
                },
                // Only the first concurrent callers wait here, while one of them loads.
                .loading => std.atomic.spinLoopHint(),
            };
        }

        pub fn available() bool {
            _ = get() catch return false;
            return true;
        }

        fn load() bool {
            for (names) |name| {
                var lib = std.DynLib.open(name) catch continue;
                if (resolve(&lib)) return true;
                lib.close();
            }
            return false;
        }

        fn resolve(lib: *std.DynLib) bool {
            inline for (comptime meta.structFields(Api)) |field| {
                @field(api, field.name) = lib.lookup(field.type, field.name) orelse return false;
            }
            return true;
        }
    };
}

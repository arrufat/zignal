//! Terminal capability detection and support utilities
//!
//! Provides cross-platform terminal detection for graphics protocols
//! (sixel, kitty, iterm2) and other terminal features.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

// Buffer size for terminal responses
const response_buffer_size: usize = 256;

// Timeout for terminal responses in milliseconds
const default_timeout_ms: u64 = 100;

/// Maximum dimension (in pixels) enforced by `aspectScale` to avoid excessive
/// terminal memory usage. Protocol encoders may rely on this cap.
pub const max_dimension: u32 = 2048;

// Windows API declarations and constants (conditionally compiled)
const win_api = if (builtin.os.tag == .windows) struct {
    // Console mode constants
    const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x0004;
    const ENABLE_LINE_INPUT: u32 = 0x0002;
    const ENABLE_ECHO_INPUT: u32 = 0x0004;

    // Standard handle constants
    const STD_INPUT_HANDLE: i32 = -10;
    const STD_OUTPUT_HANDLE: i32 = -11;

    // API functions
    extern "kernel32" fn GetStdHandle(nStdHandle: i32) callconv(.c) ?*anyopaque;
    extern "kernel32" fn GetConsoleMode(hConsoleHandle: ?*anyopaque, lpMode: *u32) callconv(.c) i32;
    extern "kernel32" fn SetConsoleMode(hConsoleHandle: ?*anyopaque, dwMode: u32) callconv(.c) i32;
    extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
    extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
    extern "c" fn _kbhit() callconv(.c) c_int;
    extern "c" fn _getch() callconv(.c) c_int;
} else void;

/// Terminal state for restoration
const TerminalState = if (builtin.os.tag == .windows) struct {
    output_mode: u32,
    input_mode: u32,
} else std.posix.termios;

/// Check if stdout is connected to a TTY
pub fn isStdoutTty(io: Io) bool {
    return Io.File.stdout().isTty(io) catch |err| switch (err) {
        error.Canceled => {
            io.recancel();
            return false;
        },
    };
}

/// Detect if the terminal supports sixel graphics protocol.
/// XTSMGRAPHICS chased with Device Attributes in one round trip, so terminals
/// that ignore XTSMGRAPHICS still reply and we don't wait out the timeout.
pub fn isSixelSupported(io: Io) !bool {
    var state: State = try .init(io);
    defer state.deinit();

    var response_buf: [response_buffer_size]u8 = undefined;
    const query_seq = "\x1b[?2;1;0S\x1b[c";

    const response = state.query(query_seq, &response_buf, default_timeout_ms) catch |err| {
        std.log.debug("sixel query: {s}", .{@errorName(err)});
        return err;
    };

    std.log.debug("sixel query response ({d} bytes): {f}", .{ response.len, std.ascii.hexEscape(response, .lower) });

    return parseSixelResponse(response);
}

/// True when a chained XTSMGRAPHICS + Device Attributes response indicates
/// sixel support. The buffer may hold either reply or both, in any order.
fn parseSixelResponse(response: []const u8) bool {
    // A DCS reply to the graphics query also signals support.
    if (std.mem.find(u8, response, "\x1bP") != null) return true;

    // Both replies start with CSI ? — tell them apart by their terminator:
    // XTSMGRAPHICS ends in 'S' (CSI ? Pi ; Ps ; Pv S), DA ends in 'c'.
    var search: usize = 0;
    while (std.mem.findPos(u8, response, search, "\x1b[?")) |start| {
        const attrs_start = start + 3;
        var i = attrs_start;
        while (i < response.len and (std.ascii.isDigit(response[i]) or response[i] == ';')) : (i += 1) {}
        const attrs = response[attrs_start..i];
        if (i >= response.len) break;

        if (response[i] == 'S') {
            // XTSMGRAPHICS reply: Ps = 0 means the query succeeded.
            if (std.mem.startsWith(u8, attrs, "2;0")) return true;
        } else if (response[i] == 'c') {
            // Device Attributes reply: standalone attribute 4 means sixel.
            var it = std.mem.splitScalar(u8, attrs, ';');
            while (it.next()) |attr| {
                if (std.mem.eql(u8, attr, "4")) return true;
            }
        }
        search = i;
    }
    return false;
}

/// Detect if the terminal supports Kitty graphics protocol
pub fn isKittySupported(io: Io) !bool {
    var state: State = try .init(io);
    defer state.deinit();

    var response_buf: [response_buffer_size]u8 = undefined;

    // Kitty graphics query chased with Device Attributes
    const query_seq = "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\\x1b[c";

    const response = state.query(query_seq, &response_buf, default_timeout_ms) catch |err| {
        std.log.debug("kitty query: {s}", .{@errorName(err)});
        return err;
    };

    std.log.debug("kitty query response ({d} bytes): {f}", .{ response.len, std.ascii.hexEscape(response, .lower) });

    // Only Kitty answers the graphics query with an "\x1b_G" response
    return std.mem.find(u8, response, "\x1b_G") != null;
}

/// Detect if the terminal supports the iTerm2 inline image protocol.
/// `OSC 1337` has no dedicated probe, so we identify the terminal via
/// XTVERSION (chased with Device Attributes): iTerm2 and WezTerm answer with
/// their name, and both implement the protocol.
pub fn isIterm2Supported(io: Io) !bool {
    var state: State = try .init(io);
    defer state.deinit();

    var response_buf: [response_buffer_size]u8 = undefined;
    const query_seq = "\x1b[>q\x1b[c";

    const response = state.query(query_seq, &response_buf, default_timeout_ms) catch |err| {
        std.log.debug("iterm2 xtversion query: {s}", .{@errorName(err)});
        return err;
    };

    std.log.debug("iterm2 query response ({d} bytes): {f}", .{ response.len, std.ascii.hexEscape(response, .lower) });

    // XTVERSION name is reported inside the DCS reply, e.g. "iTerm2 3.5.0" or
    // "WezTerm ...". Both report a stable casing, so an exact match suffices.
    return std.mem.find(u8, response, "iTerm2") != null or
        std.mem.find(u8, response, "WezTerm") != null;
}

/// True when `scale` is close enough to 1 that resampling would be imperceptible.
pub fn isIdentityScale(scale: f32) bool {
    return @abs(scale - 1.0) <= 0.001;
}

/// Compute aspect-preserving scale factor given optional target width/height.
/// Enforces `max_dimension` to avoid excessive terminal memory usage.
pub fn aspectScale(width_opt: ?u32, height_opt: ?u32, rows: usize, cols: usize) f32 {
    if (rows == 0 or cols == 0) return 1.0;
    const max_dim = max_dimension;
    const cols_f: f32 = @floatFromInt(cols);
    const rows_f: f32 = @floatFromInt(rows);

    // Compute the scale implied by user-provided constraints.
    // - both set: fit-to-box (smaller of the two ratios)
    // - one set: scale by that ratio (the other axis follows aspect)
    // - neither set: identity, then clamped below by max_dim
    var scale: f32 = 1.0;
    if (width_opt) |w| {
        const target_w: f32 = @floatFromInt(@min(w, max_dim));
        scale = target_w / cols_f;
        if (height_opt) |h| {
            const target_h: f32 = @floatFromInt(@min(h, max_dim));
            scale = @min(scale, target_h / rows_f);
        }
    } else if (height_opt) |h| {
        const target_h: f32 = @floatFromInt(@min(h, max_dim));
        scale = target_h / rows_f;
    }

    // Independently enforce the max_dim cap on the resulting dimensions.
    const max_dim_f: f32 = @floatFromInt(max_dim);
    return @min(scale, @min(max_dim_f / cols_f, max_dim_f / rows_f));
}

/// Raw-mode query/response plumbing for the capability probes: saves the
/// terminal settings on init and restores them on deinit.
const State = struct {
    io: Io,
    /// Standard input file handle
    stdin: Io.File,
    /// Standard output file handle
    stdout: Io.File,
    /// Original terminal state to restore on cleanup
    original_state: TerminalState,

    /// Save current terminal settings; on Windows also enable Virtual Terminal
    /// Processing and raw input.
    fn init(io: Io) !State {
        const stdin = Io.File.stdin();
        const stdout = Io.File.stdout();

        if (builtin.os.tag == .windows) {
            const stdin_handle = win_api.GetStdHandle(win_api.STD_INPUT_HANDLE);
            const stdout_handle = win_api.GetStdHandle(win_api.STD_OUTPUT_HANDLE);

            var original_output_mode: u32 = 0;
            var original_input_mode: u32 = 0;

            if (win_api.GetConsoleMode(stdout_handle, &original_output_mode) == 0) {
                return error.ConsoleError;
            }
            if (win_api.GetConsoleMode(stdin_handle, &original_input_mode) == 0) {
                return error.ConsoleError;
            }

            const new_output_mode = original_output_mode | win_api.ENABLE_VIRTUAL_TERMINAL_PROCESSING;
            if (win_api.SetConsoleMode(stdout_handle, new_output_mode) == 0) {
                return error.ConsoleError;
            }

            const raw_input_mode = original_input_mode & ~(win_api.ENABLE_LINE_INPUT | win_api.ENABLE_ECHO_INPUT);
            _ = win_api.SetConsoleMode(stdin_handle, raw_input_mode);

            return State{
                .io = io,
                .stdin = stdin,
                .stdout = stdout,
                .original_state = .{
                    .output_mode = original_output_mode,
                    .input_mode = original_input_mode,
                },
            };
        } else {
            const original = try std.posix.tcgetattr(stdin.handle);

            return State{
                .io = io,
                .stdin = stdin,
                .stdout = stdout,
                .original_state = original,
            };
        }
    }

    /// Restore the terminal to its original state.
    fn deinit(self: *State) void {
        if (builtin.os.tag == .windows) {
            const stdin_handle = win_api.GetStdHandle(win_api.STD_INPUT_HANDLE);
            const stdout_handle = win_api.GetStdHandle(win_api.STD_OUTPUT_HANDLE);
            _ = win_api.SetConsoleMode(stdout_handle, self.original_state.output_mode);
            _ = win_api.SetConsoleMode(stdin_handle, self.original_state.input_mode);
        } else {
            self.restoreTermios();
        }
    }

    /// Restore the saved termios (no-op on Windows, where deinit restores console modes).
    fn restoreTermios(self: *const State) void {
        if (builtin.os.tag != .windows) {
            std.posix.tcsetattr(self.stdin.handle, .FLUSH, self.original_state) catch {};
        }
    }

    /// Disable canonical mode and echo so responses can be read unbuffered.
    /// Windows is already in raw mode from init.
    fn enterRawMode(self: *const State) !void {
        if (builtin.os.tag != .windows) {
            var raw = self.original_state;

            raw.lflag.ICANON = false;
            raw.lflag.ECHO = false;

            raw.cc[@backingInt(std.posix.V.MIN)] = 0;
            raw.cc[@backingInt(std.posix.V.TIME)] = 1; // 0.1 second timeout

            try std.posix.tcsetattr(self.stdin.handle, .FLUSH, raw);
        }
    }

    /// Read a terminal response within `timeout_ms`, returning the bytes read
    /// (0 on timeout). Windows polls _kbhit/_getch; POSIX relies on termios VTIME.
    fn readWithTimeout(self: *const State, buffer: []u8, timeout_ms: u64) !usize {
        if (builtin.os.tag == .windows) {
            const start_time = win_api.GetTickCount64();
            var total_read: usize = 0;

            poll: while (win_api.GetTickCount64() - start_time < timeout_ms) {
                // Drain all queued input before sleeping
                while (win_api._kbhit() != 0) {
                    const ch = win_api._getch();
                    if (ch >= 0 and ch <= 255) {
                        buffer[total_read] = @intCast(ch);
                        total_read += 1;

                        if (total_read >= buffer.len) break :poll;

                        // Stop at common response terminators
                        const char: u8 = @intCast(ch);
                        if ((char == 'c' or char == 'R' or char == '\\' or char == ';') and total_read > 3) {
                            break :poll;
                        }
                    }
                }

                win_api.Sleep(1);
            }

            return total_read;
        } else {
            var iov = [_][]u8{buffer};
            return self.stdin.readStreaming(self.io, &iov) catch |err| switch (err) {
                // VMIN=0/VTIME>0 returns 0 bytes on timeout — surfaced as
                // EndOfStream by the I/O layer. Caller maps 0 bytes to NoResponse.
                error.EndOfStream => 0,
                error.Canceled => {
                    self.io.recancel();
                    return err;
                },
                else => return err,
            };
        }
    }

    /// Send a query sequence and return the response (error.NoResponse on timeout).
    /// enterRawMode uses TCSAFLUSH, which discards pending input before applying
    /// the new termios; Windows drains explicitly since console state is global.
    fn query(self: *const State, sequence: []const u8, buffer: []u8, timeout_ms: u64) ![]const u8 {
        try self.enterRawMode();
        defer self.restoreTermios();

        if (builtin.os.tag == .windows) {
            while (win_api._kbhit() != 0) {
                _ = win_api._getch();
            }
        }

        self.stdout.writeStreamingAll(self.io, sequence) catch |err| {
            if (err == error.Canceled) self.io.recancel();
            return err;
        };

        const n = try self.readWithTimeout(buffer, timeout_ms);
        if (n == 0) return error.NoResponse;
        return buffer[0..n];
    }
};

test "parseSixelResponse: DA reply with standalone attribute 4" {
    try std.testing.expect(parseSixelResponse("\x1b[?62;1;4;22c"));
    try std.testing.expect(parseSixelResponse("\x1b[?4c"));
}

test "parseSixelResponse: DA reply without sixel attribute" {
    try std.testing.expect(!parseSixelResponse("\x1b[?62;1;22c"));
    // 44 must not match as a standalone 4
    try std.testing.expect(!parseSixelResponse("\x1b[?62;44c"));
}

test "parseSixelResponse: XTSMGRAPHICS success reply" {
    try std.testing.expect(parseSixelResponse("\x1b[?2;0;256S"));
    // Ps != 0 means the query failed
    try std.testing.expect(!parseSixelResponse("\x1b[?2;1;0S"));
}

test "parseSixelResponse: combined XTSMGRAPHICS + DA replies" {
    // Failed graphics query followed by a DA reply advertising sixel
    try std.testing.expect(parseSixelResponse("\x1b[?2;1;0S\x1b[?62;4c"));
    // Neither reply indicates support
    try std.testing.expect(!parseSixelResponse("\x1b[?2;3;0S\x1b[?62;22c"));
}

test "parseSixelResponse: DCS reply" {
    try std.testing.expect(parseSixelResponse("\x1bP1$r2;1;0S\x1b\\"));
}

test "parseSixelResponse: empty or garbage" {
    try std.testing.expect(!parseSixelResponse(""));
    try std.testing.expect(!parseSixelResponse("\x1b[?"));
    try std.testing.expect(!parseSixelResponse("hello"));
}

test "aspectScale: only width given upscales" {
    // 100x100 image, --width 1000 → scale 10x
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), aspectScale(1000, null, 100, 100), 1e-6);
}

test "aspectScale: only height given upscales" {
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), aspectScale(null, 400, 100, 100), 1e-6);
}

test "aspectScale: only width given downscales" {
    // 800x600 image (rows=600, cols=800), --width 100 → scale 0.125
    try std.testing.expectApproxEqAbs(@as(f32, 0.125), aspectScale(100, null, 600, 800), 1e-6);
}

test "aspectScale: both dims fit-to-box" {
    // 100x100 image, box 800x600 → scale by smaller ratio (6.0)
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), aspectScale(800, 600, 100, 100), 1e-6);
}

test "aspectScale: neither given returns 1.0 for small images" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), aspectScale(null, null, 600, 800), 1e-6);
}

test "aspectScale: max_dim caps oversized images" {
    // 4096x4096 image, no constraints → cap at 2048/4096 = 0.5
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), aspectScale(null, null, 4096, 4096), 1e-6);
}

test "aspectScale: max_dim caps user-requested upscale" {
    // 100x100 image, --width 5000 → capped at 2048/100 = 20.48
    try std.testing.expectApproxEqAbs(@as(f32, 20.48), aspectScale(5000, null, 100, 100), 1e-4);
}

test "aspectScale: zero dimensions return identity (no inf/NaN)" {
    // Division by zero would produce inf, then NaN on @round(0 * inf), then a
    // panic on the int cast. Guard returns 1.0 instead.
    try std.testing.expectEqual(@as(f32, 1.0), aspectScale(100, null, 0, 100));
    try std.testing.expectEqual(@as(f32, 1.0), aspectScale(100, null, 100, 0));
    try std.testing.expectEqual(@as(f32, 1.0), aspectScale(null, null, 0, 0));
}

//! Terminal capability detection and support utilities
//!
//! Provides cross-platform terminal detection for graphics protocols
//! (sixel, kitty, iterm2) and other terminal features.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

// Buffer size for terminal responses
const response_buffer_size: usize = 256;

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
const TerminalState = union(enum) {
    windows: struct {
        output_mode: u32,
        input_mode: u32,
    },
    posix: std.posix.termios,
};

/// Configuration options for terminal detection
pub const DetectionOptions = struct {
    /// Timeout for terminal responses in milliseconds
    timeout_ms: u64 = 100,
    /// Enable functional test (may cause visible output)
    enable_functional_test: bool = false,
};

/// Check if stdout is connected to a TTY
pub fn isStdoutTty(io: Io) bool {
    return Io.File.stdout().isTty(io) catch |err| switch (err) {
        error.Canceled => {
            io.recancel();
            return false;
        },
    };
}

/// Detect if the terminal supports sixel graphics protocol
pub fn isSixelSupported(io: Io) !bool {
    var state: State = try .init(io);
    defer state.deinit();

    // Try DECRQSS - Request Status String (no visible output)
    if (state.checkSixelSupport(.param_query)) return true;

    // Try Device Attributes (no visible output)
    if (state.checkSixelSupport(.device_attributes)) return true;

    return false;
}

/// Detect if the terminal supports Kitty graphics protocol
pub fn isKittySupported(io: Io) !bool {
    var state: State = try .init(io);
    defer state.deinit();

    var response_buf: [response_buffer_size]u8 = undefined;

    // Send Kitty graphics query followed by device attributes
    // This allows us to detect Kitty support by checking which response we get
    const query_seq = "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\\x1b[c";

    const response = state.query(query_seq, &response_buf, 100) catch |err| {
        std.log.debug("kitty query: {s}", .{@errorName(err)});
        return err;
    };

    std.log.debug("kitty query response ({d} bytes): {f}", .{ response.len, std.ascii.hexEscape(response, .lower) });

    // If we get a graphics query response, Kitty is supported
    // The response will contain "\x1b_G" if Kitty processed the graphics query
    return std.mem.find(u8, response, "\x1b_G") != null;
}

/// Detect if the terminal supports the iTerm2 inline image protocol.
///
/// iTerm2 inline images (`OSC 1337`) have no dedicated probe, so we identify the
/// terminal via XTVERSION (`CSI > q`), which iTerm2 and WezTerm answer with a
/// `DCS > | <name> ST` string naming themselves; both implement the protocol.
/// The query is chased with primary Device Attributes so terminals that ignore
/// XTVERSION still reply and we don't wait out the full timeout.
pub fn isIterm2Supported(io: Io) !bool {
    var state: State = try .init(io);
    defer state.deinit();

    var response_buf: [response_buffer_size]u8 = undefined;
    const query_seq = "\x1b[>q\x1b[c";

    const response = state.query(query_seq, &response_buf, 100) catch |err| {
        std.log.debug("iterm2 xtversion query: {s}", .{@errorName(err)});
        return err;
    };

    std.log.debug("iterm2 query response ({d} bytes): {f}", .{ response.len, std.ascii.hexEscape(response, .lower) });

    // XTVERSION name is reported inside the DCS reply, e.g. "iTerm2 3.5.0" or
    // "WezTerm ...". Both report a stable casing, so an exact match suffices.
    return std.mem.find(u8, response, "iTerm2") != null or
        std.mem.find(u8, response, "WezTerm") != null;
}

/// Compute aspect-preserving scale factor given optional target width/height.
/// Enforces a maximum dimension of 2048 pixels to avoid excessive terminal memory usage.
pub fn aspectScale(width_opt: ?u32, height_opt: ?u32, rows: usize, cols: usize) f32 {
    if (rows == 0 or cols == 0) return 1.0;
    const max_dim: u32 = 2048;
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

/// Terminal state manager for capability detection
///
/// This struct handles terminal state management for detecting graphics protocol
/// support. It saves the original terminal settings on initialization and restores
/// them on cleanup, ensuring the terminal is left in its original state.
///
/// The State struct provides methods for:
/// - Entering raw mode for reading terminal responses
/// - Sending queries and reading responses with timeouts
/// - Checking for specific terminal capabilities
///
/// Usage:
/// ```zig
/// var state: State = try .init();
/// defer state.deinit();
/// const supported = state.checkSixelSupport(.device_attributes);
/// ```
const State = struct {
    io: Io,
    /// Standard input file handle
    stdin: Io.File,
    /// Standard output file handle
    stdout: Io.File,
    /// Standard error file handle
    stderr: Io.File,
    /// Original terminal state to restore on cleanup
    original_state: TerminalState,

    /// Initialize terminal state for capability detection
    ///
    /// Saves the current terminal settings and prepares for raw mode operations.
    /// On Windows, enables Virtual Terminal Processing for SGR sequence support.
    /// On POSIX systems, saves the current termios settings.
    ///
    /// Returns an error if terminal initialization fails.
    fn init(io: Io) !State {
        const stdin = Io.File.stdin();
        const stdout = Io.File.stdout();
        const stderr = Io.File.stderr();

        if (builtin.os.tag == .windows) {
            // Windows-specific initialization
            const stdin_handle = win_api.GetStdHandle(win_api.STD_INPUT_HANDLE);
            const stdout_handle = win_api.GetStdHandle(win_api.STD_OUTPUT_HANDLE);

            // Save original console modes
            var original_output_mode: u32 = 0;
            var original_input_mode: u32 = 0;

            if (win_api.GetConsoleMode(stdout_handle, &original_output_mode) == 0) {
                return error.ConsoleError;
            }
            if (win_api.GetConsoleMode(stdin_handle, &original_input_mode) == 0) {
                return error.ConsoleError;
            }

            // Enable Virtual Terminal Processing for SGR sequences
            const new_output_mode = original_output_mode | win_api.ENABLE_VIRTUAL_TERMINAL_PROCESSING;
            if (win_api.SetConsoleMode(stdout_handle, new_output_mode) == 0) {
                return error.ConsoleError;
            }

            // Set input mode for raw reading
            const raw_input_mode = original_input_mode & ~(win_api.ENABLE_LINE_INPUT | win_api.ENABLE_ECHO_INPUT);
            _ = win_api.SetConsoleMode(stdin_handle, raw_input_mode);

            return State{
                .io = io,
                .stdin = stdin,
                .stdout = stdout,
                .stderr = stderr,
                .original_state = .{ .windows = .{
                    .output_mode = original_output_mode,
                    .input_mode = original_input_mode,
                } },
            };
        } else {
            // POSIX: Get current terminal settings
            const original = try std.posix.tcgetattr(stdin.handle);

            return State{
                .io = io,
                .stdin = stdin,
                .stdout = stdout,
                .stderr = stderr,
                .original_state = .{ .posix = original },
            };
        }
    }

    /// Restore terminal to its original state
    ///
    /// This method must be called to properly clean up and restore the terminal
    /// settings that were saved during initialization. Always use defer to ensure
    /// cleanup happens even if an error occurs.
    fn deinit(self: *State) void {
        switch (self.original_state) {
            .windows => |win_state| {
                if (builtin.os.tag == .windows) {
                    // Restore original console modes
                    const stdin_handle = win_api.GetStdHandle(win_api.STD_INPUT_HANDLE);
                    const stdout_handle = win_api.GetStdHandle(win_api.STD_OUTPUT_HANDLE);
                    _ = win_api.SetConsoleMode(stdout_handle, win_state.output_mode);
                    _ = win_api.SetConsoleMode(stdin_handle, win_state.input_mode);
                }
            },
            .posix => |termios| {
                if (builtin.os.tag != .windows) {
                    // Restore original terminal settings
                    std.posix.tcsetattr(self.stdin.handle, .FLUSH, termios) catch {};
                }
            },
        }
    }

    /// Enter raw mode for reading terminal responses
    ///
    /// Disables canonical mode and echo to allow reading individual characters
    /// from the terminal without line buffering. On Windows, this is already
    /// handled during initialization.
    fn enterRawMode(self: *const State) !void {
        switch (self.original_state) {
            .windows => {
                // Already in raw mode from init
            },
            .posix => |original| {
                if (builtin.os.tag != .windows) {
                    var raw = original;

                    // Disable canonical mode and echo
                    raw.lflag.ICANON = false;
                    raw.lflag.ECHO = false;

                    // Set minimum characters and timeout
                    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
                    raw.cc[@intFromEnum(std.posix.V.TIME)] = 1; // 0.1 second timeout

                    try std.posix.tcsetattr(self.stdin.handle, .FLUSH, raw);
                }
            },
        }
    }

    /// Read terminal response with timeout
    ///
    /// Attempts to read a response from the terminal within the specified timeout.
    /// Returns the number of bytes read, or error.NoResponse if timeout expires.
    ///
    /// On Windows, uses _kbhit() and _getch() for non-blocking reads.
    /// On POSIX, relies on termios timeout settings.
    fn readWithTimeout(self: *const State, buffer: []u8, timeout_ms: u64) !usize {
        if (builtin.os.tag == .windows) {
            const start_time = win_api.GetTickCount64();
            var total_read: usize = 0;

            while (win_api.GetTickCount64() - start_time < timeout_ms) {
                // Check if console has input available
                if (win_api._kbhit() != 0) {
                    // Read one character
                    const ch = win_api._getch();
                    if (ch >= 0 and ch <= 255) {
                        buffer[total_read] = @intCast(ch);
                        total_read += 1;

                        if (total_read >= buffer.len) break;

                        // Check for response terminators
                        const char: u8 = @intCast(ch);
                        if ((char == 'c' or char == 'R' or char == '\\' or char == ';') and total_read > 3) {
                            break;
                        }
                    }
                }

                // Small delay to prevent busy waiting
                win_api.Sleep(1);
            }

            return total_read;
        } else {
            // POSIX: Use the existing termios timeout mechanism
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

    /// Send a query sequence and read the response
    ///
    /// Sends an escape sequence to the terminal and waits for a response.
    /// Returns the response data or error.NoResponse if no response received.
    /// Note: enterRawMode uses TCSAFLUSH, which discards any pending input
    /// before applying the new termios — so no explicit drain is needed here.
    /// On Windows, drain the input buffer first since console state is global.
    fn query(self: *const State, sequence: []const u8, buffer: []u8, timeout_ms: u64) ![]const u8 {
        try self.enterRawMode();
        defer {
            switch (self.original_state) {
                .windows => {},
                .posix => |termios| {
                    if (builtin.os.tag != .windows) {
                        std.posix.tcsetattr(self.stdin.handle, .FLUSH, termios) catch {};
                    }
                },
            }
        }

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

    /// Check sixel support using a specific query method
    ///
    /// Attempts to detect sixel support using either:
    /// - param_query: DECRQSS query for sixel parameters
    /// - device_attributes: Primary Device Attributes query looking for attribute 4
    ///
    /// Returns true if the terminal responds with sixel support indication.
    fn checkSixelSupport(self: *const State, method: enum { param_query, device_attributes }) bool {
        var response_buf: [response_buffer_size]u8 = undefined;

        switch (method) {
            .param_query => {
                // Query sixel graphics parameter
                const response = self.query("\x1b[?2;1;0S", &response_buf, 100) catch |err| {
                    std.log.debug("sixel param_query: {s}", .{@errorName(err)});
                    return false;
                };

                std.log.debug("sixel param_query response ({d} bytes): {f}", .{ response.len, std.ascii.hexEscape(response, .lower) });

                // Look for positive response indicating sixel support
                // Expected format: ESC P 1 $ r <params> ESC \
                return response.len >= 4 and std.mem.find(u8, response, "\x1bP") != null;
            },
            .device_attributes => {
                // Send Primary Device Attributes query
                const response = self.query("\x1b[c", &response_buf, 100) catch |err| {
                    std.log.debug("sixel device_attributes: {s}", .{@errorName(err)});
                    return false;
                };

                std.log.debug("sixel device_attributes response ({d} bytes): {f}", .{ response.len, std.ascii.hexEscape(response, .lower) });

                // Parse response looking for attribute 4 (sixel graphics)
                // Format: ESC [ ? <attributes> c
                if (response.len >= 4 and response[0] == '\x1b' and response[1] == '[' and response[2] == '?') {
                    // Look for '4' in the attribute list
                    var i: usize = 3;
                    while (i < response.len and response[i] != 'c') : (i += 1) {
                        if (response[i] == '4') {
                            // Check it's a standalone 4, not part of another number
                            const prev_is_separator = (i == 3 or response[i - 1] == ';');
                            const next_is_separator = (i + 1 >= response.len or response[i + 1] == ';' or response[i + 1] == 'c');
                            if (prev_is_separator and next_is_separator) {
                                return true;
                            }
                        }
                    }
                }
                return false;
            },
        }
    }
};

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

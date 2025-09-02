//! Terminal capability detection and support utilities
//!
//! Provides cross-platform terminal detection for graphics protocols
//! (sixel, kitty) and other terminal features.

const std = @import("std");
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
pub fn isStdoutTty() bool {
    return std.fs.File.stdout().isTty();
}

/// Detect if the terminal supports sixel graphics protocol
pub fn isSixelSupported() !bool {
    var state: State = try .init();
    defer state.deinit();

    // Try DECRQSS - Request Status String (no visible output)
    if (state.checkSixelSupport(.param_query)) return true;

    // Try Device Attributes (no visible output)
    if (state.checkSixelSupport(.device_attributes)) return true;

    return false;
}

/// Detect if the terminal supports Kitty graphics protocol
pub fn isKittySupported() !bool {
    var state: State = try .init();
    defer state.deinit();

    var response_buf: [response_buffer_size]u8 = undefined;

    // Send Kitty graphics query followed by device attributes
    // This allows us to detect Kitty support by checking which response we get
    const query_seq = "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\\x1b[c";

    const response = try state.query(query_seq, &response_buf, 100);

    // If we get a graphics query response, Kitty is supported
    // The response will contain "\x1b_G" if Kitty processed the graphics query
    return std.mem.indexOf(u8, response, "\x1b_G") != null;
}

/// Compute aspect-preserving scale factor given optional target width/height.
/// Returns 1.0 when both are null, or the smaller scale when both are set.
pub fn aspectScale(width_opt: ?u32, height_opt: ?u32, rows: usize, cols: usize) f32 {
    if (width_opt == null and height_opt == null) return 1.0;
    var scale_x: f32 = 1.0;
    var scale_y: f32 = 1.0;
    if (width_opt) |w| {
        scale_x = @as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(cols));
    }
    if (height_opt) |h| {
        scale_y = @as(f32, @floatFromInt(h)) / @as(f32, @floatFromInt(rows));
    }
    return @min(scale_x, scale_y);
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
    /// Standard input file handle
    stdin: std.fs.File,
    /// Standard output file handle
    stdout: std.fs.File,
    /// Standard error file handle
    stderr: std.fs.File,
    /// Original terminal state to restore on cleanup
    original_state: TerminalState,

    /// Initialize terminal state for capability detection
    ///
    /// Saves the current terminal settings and prepares for raw mode operations.
    /// On Windows, enables Virtual Terminal Processing for SGR sequence support.
    /// On POSIX systems, saves the current termios settings.
    ///
    /// Returns an error if terminal initialization fails.
    fn init() !State {
        const stdin = std.fs.File.stdin();
        const stdout = std.fs.File.stdout();
        const stderr = std.fs.File.stderr();

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
            const start_time = std.time.milliTimestamp();
            var total_read: usize = 0;

            while (std.time.milliTimestamp() - start_time < timeout_ms) {
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
                std.Thread.sleep(1_000_000); // 1ms
            }

            return total_read;
        } else {
            // POSIX: Use the existing termios timeout mechanism
            return try self.stdin.read(buffer);
        }
    }

    /// Send a query sequence and read the response
    ///
    /// Sends an escape sequence to the terminal and waits for a response.
    /// Automatically enters raw mode, clears pending input, and restores
    /// terminal state after reading the response.
    ///
    /// Returns the response data or error.NoResponse if no response received.
    fn query(self: *const State, sequence: []const u8, buffer: []u8, timeout_ms: u64) ![]const u8 {
        // Enter raw mode
        try self.enterRawMode();
        defer {
            // Restore terminal state
            switch (self.original_state) {
                .windows => {},
                .posix => |termios| {
                    if (builtin.os.tag != .windows) {
                        std.posix.tcsetattr(self.stdin.handle, .FLUSH, termios) catch {};
                    }
                },
            }
        }

        // Clear any pending input
        if (builtin.os.tag == .windows) {
            // Consume any pending input
            while (win_api._kbhit() != 0) {
                _ = win_api._getch();
            }
        } else {
            var discard_buf: [response_buffer_size]u8 = undefined;
            _ = self.stdin.read(&discard_buf) catch 0;
        }

        // Send query sequence
        _ = try self.stdout.write(sequence);

        // Read response with timeout
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
                const response = self.query("\x1b[?2;1;0S", &response_buf, 100) catch {
                    return false;
                };

                // Look for positive response indicating sixel support
                // Expected format: ESC P 1 $ r <params> ESC \
                return response.len >= 4 and std.mem.indexOf(u8, response, "\x1bP") != null;
            },
            .device_attributes => {
                // Send Primary Device Attributes query
                const response = self.query("\x1b[c", &response_buf, 100) catch {
                    return false;
                };

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

//! Font file compression utilities
//!
//! This module provides shared utilities for loading font files,
//! which may be compressed with gzip.

const std = @import("std");
const gzip = @import("../compression/gzip.zig");

/// Result of loadFile operation
pub const LoadedFile = struct {
    /// The file data (either raw or decompressed)
    data: []u8,
    /// Raw file data (always owned, must be freed)
    raw_data: []u8,
    /// Decompressed data if applicable (must be freed if not null)
    decompressed_data: ?[]u8,
    /// Whether the file was compressed
    was_compressed: bool,

    /// Clean up allocated memory
    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.raw_data);
        if (self.decompressed_data) |data| {
            allocator.free(data);
        }
    }
};

/// Load a file and automatically decompress if it's gzip compressed
pub fn loadFile(allocator: std.mem.Allocator, path: []const u8, max_size: usize) !LoadedFile {
    // Check if file is gzip compressed
    const is_compressed = std.ascii.endsWithIgnoreCase(path, ".gz");

    // Read entire file into memory
    const raw_file_contents = try std.fs.cwd().readFileAlloc(path, allocator, std.Io.Limit.limited(max_size));
    errdefer allocator.free(raw_file_contents);

    if (is_compressed) {
        const decompressed_data = try gzip.decompress(allocator, raw_file_contents);
        std.log.info("Decompressed {s} from {} bytes to {} bytes", .{ path, raw_file_contents.len, decompressed_data.len });

        return LoadedFile{
            .data = decompressed_data,
            .raw_data = raw_file_contents,
            .decompressed_data = decompressed_data,
            .was_compressed = true,
        };
    } else {
        return LoadedFile{
            .data = raw_file_contents,
            .raw_data = raw_file_contents,
            .decompressed_data = null,
            .was_compressed = false,
        };
    }
}


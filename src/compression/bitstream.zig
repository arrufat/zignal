//! Bit-level I/O utilities for DEFLATE

const std = @import("std");
const ArrayList = std.ArrayList;

/// Bit stream reader for DEFLATE (LSB-first within bytes)
pub const BitReader = struct {
    data: []const u8,
    byte_pos: usize = 0,
    bit_pos: u8 = 0, // 0-7, position within current byte

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data };
    }

    pub fn readBits(self: *BitReader, num_bits: u8) !u32 {
        std.debug.assert(num_bits <= 32);

        var result: u32 = 0;
        var bits_read: u8 = 0;

        while (bits_read < num_bits) {
            if (self.byte_pos >= self.data.len) {
                return error.UnexpectedEndOfData;
            }

            const current_byte = self.data[self.byte_pos];
            const bits_in_byte = 8 - self.bit_pos;
            const bits_needed = num_bits - bits_read;
            const bits_to_read = @min(bits_needed, bits_in_byte);

            // bits_to_read <= 8 and bit_pos <= 7, so truncation is always valid
            const mask = if (bits_to_read == 8) @as(u8, 0xFF) else (@as(u8, 1) << @truncate(bits_to_read)) - 1;
            const bits = (current_byte >> @truncate(self.bit_pos)) & mask;
            result |= @as(u32, bits) << @truncate(bits_read);

            bits_read += bits_to_read;
            self.bit_pos += bits_to_read;

            if (self.bit_pos >= 8) {
                self.bit_pos = 0;
                self.byte_pos += 1;
            }
        }

        return result;
    }

    pub fn skipToByteBoundary(self: *BitReader) void {
        if (self.bit_pos != 0) {
            self.bit_pos = 0;
            self.byte_pos += 1;
        }
    }

    pub fn readBytes(self: *BitReader, buffer: []u8) !void {
        self.skipToByteBoundary();
        if (self.byte_pos + buffer.len > self.data.len) {
            return error.UnexpectedEndOfData;
        }
        @memcpy(buffer, self.data[self.byte_pos .. self.byte_pos + buffer.len]);
        self.byte_pos += buffer.len;
    }
};

/// Bit writer for variable-length codes (LSB-first within bytes)
pub const BitWriter = struct {
    output: *ArrayList(u8),
    bit_buffer: u32 = 0,
    bit_count: u8 = 0,

    pub fn init(output: *ArrayList(u8)) BitWriter {
        return .{ .output = output };
    }

    pub fn writeBits(self: *BitWriter, gpa: std.mem.Allocator, code: u32, bits: u8) !void {
        self.bit_buffer |= code << @truncate(self.bit_count);
        self.bit_count += bits;

        while (self.bit_count >= 8) {
            try self.output.append(gpa, @intCast(self.bit_buffer & 0xFF));
            self.bit_buffer >>= 8;
            self.bit_count -= 8;
        }
    }

    pub fn flush(self: *BitWriter, gpa: std.mem.Allocator) !void {
        if (self.bit_count > 0) {
            try self.output.append(gpa, @intCast(self.bit_buffer & 0xFF));
            self.bit_buffer = 0;
            self.bit_count = 0;
        }
    }
};

//! Pure Zig JPEG decoder implementation.
//! Supports baseline DCT JPEG images with common chroma subsampling.
//! Zero dependencies - implements all required algorithms internally.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const convertColor = @import("color.zig").convertColor;
const Image = @import("image.zig").Image;
const Rgb = @import("color.zig").Rgb;
const Rgba = @import("color.zig").Rgba;
const Ycbcr = @import("color.zig").Ycbcr;

// JPEG markers
const Marker = enum(u16) {
    // Start of Frame markers
    SOF0 = 0xFFC0, // Baseline DCT
    SOF1 = 0xFFC1, // Extended sequential DCT
    SOF2 = 0xFFC2, // Progressive DCT
    SOF3 = 0xFFC3, // Lossless (sequential)

    // Huffman table
    DHT = 0xFFC4,

    // Arithmetic coding conditioning
    DAC = 0xFFCC,

    // Restart interval markers
    RST0 = 0xFFD0,
    RST1 = 0xFFD1,
    RST2 = 0xFFD2,
    RST3 = 0xFFD3,
    RST4 = 0xFFD4,
    RST5 = 0xFFD5,
    RST6 = 0xFFD6,
    RST7 = 0xFFD7,

    // Other markers
    SOI = 0xFFD8, // Start of Image
    EOI = 0xFFD9, // End of Image
    SOS = 0xFFDA, // Start of Scan
    DQT = 0xFFDB, // Quantization Table
    DNL = 0xFFDC, // Number of Lines
    DRI = 0xFFDD, // Restart Interval
    DHP = 0xFFDE, // Hierarchical Progression
    EXP = 0xFFDF, // Expand Reference Component

    // Application segments
    APP0 = 0xFFE0, // JFIF
    APP1 = 0xFFE1, // EXIF
    APP2 = 0xFFE2,
    APP3 = 0xFFE3,
    APP4 = 0xFFE4,
    APP5 = 0xFFE5,
    APP6 = 0xFFE6,
    APP7 = 0xFFE7,
    APP8 = 0xFFE8,
    APP9 = 0xFFE9,
    APP10 = 0xFFEA,
    APP11 = 0xFFEB,
    APP12 = 0xFFEC,
    APP13 = 0xFFED,
    APP14 = 0xFFEE,
    APP15 = 0xFFEF,

    // Comment
    COM = 0xFFFE,

    pub fn fromBytes(bytes: [2]u8) ?Marker {
        const value = (@as(u16, bytes[0]) << 8) | bytes[1];
        return std.meta.intToEnum(Marker, value) catch null;
    }
};

// Component info from SOF
const Component = struct {
    id: u8,
    h_sampling: u4,
    v_sampling: u4,
    quant_table_id: u8,
};

// Scan component info from SOS
const ScanComponent = struct {
    component_id: u8,
    dc_table_id: u4,
    ac_table_id: u4,
};

// JPEG decoder state
pub const JpegDecoder = struct {
    allocator: Allocator,

    // Image properties
    width: u16,
    height: u16,
    num_components: u8,
    components: [4]Component = undefined,

    // Huffman tables (0-3 for DC, 0-3 for AC)
    dc_tables: [4]?HuffmanTable = .{ null, null, null, null },
    ac_tables: [4]?HuffmanTable = .{ null, null, null, null },

    // Quantization tables
    quant_tables: [4]?[64]u16 = .{ null, null, null, null },

    // Scan data
    scan_components: []ScanComponent = undefined,
    restart_interval: u16 = 0,

    // Bit reader for entropy-coded data
    bit_reader: BitReader = undefined,

    // Block dimensions
    block_width: u16 = 0,
    block_height: u16 = 0,
    block_width_actual: u16 = 0,
    block_height_actual: u16 = 0,

    // Block storage for all components
    block_storage: ?[][4][64]i32 = null,

    // Separate RGB storage to avoid overwriting chroma data
    rgb_storage: ?[][3][64]u8 = null,

    pub fn init(allocator: Allocator) JpegDecoder {
        return .{
            .allocator = allocator,
            .width = 0,
            .height = 0,
            .num_components = 0,
            .scan_components = &[_]ScanComponent{},
        };
    }

    pub fn deinit(self: *JpegDecoder) void {
        for (&self.dc_tables) |*table| {
            if (table.*) |*t| t.deinit(self.allocator);
        }
        for (&self.ac_tables) |*table| {
            if (table.*) |*t| t.deinit(self.allocator);
        }
        if (self.scan_components.len > 0) {
            self.allocator.free(self.scan_components);
        }
        if (self.block_storage) |storage| {
            self.allocator.free(storage);
        }
        if (self.rgb_storage) |storage| {
            self.allocator.free(storage);
        }
    }

    // Parse Start of Frame (SOF0) marker
    pub fn parseSOF(self: *JpegDecoder, data: []const u8) !void {
        if (data.len < 8) return error.InvalidSOF;

        const length = (@as(u16, data[0]) << 8) | data[1];
        if (data.len < length) return error.InvalidSOF;

        const precision = data[2];
        if (precision != 8) return error.UnsupportedJpegFormat; // Only 8-bit precision supported

        self.height = (@as(u16, data[3]) << 8) | data[4];
        self.width = (@as(u16, data[5]) << 8) | data[6];
        self.num_components = data[7];

        if (self.num_components != 1 and self.num_components != 3) {
            return error.InvalidComponentCount;
        }

        // Parse component information
        var pos: usize = 8;
        var max_h_sampling: u4 = 0;
        var max_v_sampling: u4 = 0;

        for (0..self.num_components) |i| {
            if (pos + 3 > data.len) return error.InvalidSOF;

            self.components[i] = .{
                .id = data[pos],
                .h_sampling = @intCast(data[pos + 1] >> 4),
                .v_sampling = @intCast(data[pos + 1] & 0x0F),
                .quant_table_id = data[pos + 2],
            };

            max_h_sampling = @max(max_h_sampling, self.components[i].h_sampling);
            max_v_sampling = @max(max_v_sampling, self.components[i].v_sampling);

            pos += 3;
        }

        // Validate sampling factors
        if (max_h_sampling > 4 or max_v_sampling > 4) {
            return error.InvalidComponentCount;
        }

        // Calculate block dimensions
        const mcu_width = 8 * @as(u32, max_h_sampling);
        const mcu_height = 8 * @as(u32, max_v_sampling);
        const width_actual = ((@as(u32, self.width) + mcu_width - 1) / mcu_width) * mcu_width;
        const height_actual = ((@as(u32, self.height) + mcu_height - 1) / mcu_height) * mcu_height;

        self.block_width = (self.width + 7) / 8;
        self.block_height = (self.height + 7) / 8;
        self.block_width_actual = @intCast((width_actual + 7) / 8);
        self.block_height_actual = @intCast((height_actual + 7) / 8);

        // Allocate block storage
        const total_blocks = @as(usize, width_actual) * height_actual / 64;
        self.block_storage = try self.allocator.alloc([4][64]i32, total_blocks);

        // Allocate separate RGB storage
        self.rgb_storage = try self.allocator.alloc([3][64]u8, total_blocks);

        // Initialize block storage to zero
        for (self.block_storage.?) |*block_set| {
            for (block_set) |*block| {
                @memset(block, 0);
            }
        }

        // Initialize RGB storage to zero
        for (self.rgb_storage.?) |*rgb_block| {
            for (rgb_block) |*channel| {
                @memset(channel, 0);
            }
        }
    }

    // Parse Define Huffman Table (DHT) marker
    pub fn parseDHT(self: *JpegDecoder, data: []const u8) !void {
        if (data.len < 2) return error.InvalidDHT;

        const length = (@as(u16, data[0]) << 8) | data[1];
        if (data.len < length) return error.InvalidDHT;

        var pos: usize = 2;

        while (pos < length) {
            if (pos + 17 > length) return error.InvalidDHT;

            const table_info = data[pos];
            const table_class = (table_info >> 4) & 1; // 0 = DC, 1 = AC
            const table_id = table_info & 0x0F;

            if (table_id > 3) return error.InvalidHuffmanTable;

            pos += 1;

            // Read 16 bytes of bit lengths
            var bits: [16]u8 = undefined;
            @memcpy(&bits, data[pos .. pos + 16]);
            pos += 16;

            // Count total number of codes
            var total_codes: u16 = 0;
            for (bits) |count| {
                total_codes += count;
            }

            if (pos + total_codes > length) return error.InvalidDHT;

            // Allocate and read huffman values
            const huffval = try self.allocator.alloc(u8, total_codes);
            @memcpy(huffval, data[pos .. pos + total_codes]);
            pos += total_codes;

            // Build Huffman table
            var table = HuffmanTable{
                .bits = bits,
                .huffval = huffval,
                .mincode = undefined,
                .maxcode = undefined,
                .valptr = undefined,
            };

            // Generate decoding tables
            try generateHuffmanTables(&table);

            // Store table
            if (table_class == 0) {
                if (self.dc_tables[table_id]) |*old_table| {
                    old_table.deinit(self.allocator);
                }
                self.dc_tables[table_id] = table;
            } else {
                if (self.ac_tables[table_id]) |*old_table| {
                    old_table.deinit(self.allocator);
                }
                self.ac_tables[table_id] = table;
            }
        }
    }

    // Parse Define Quantization Table (DQT) marker
    pub fn parseDQT(self: *JpegDecoder, data: []const u8) !void {
        if (data.len < 2) return error.InvalidDQT;

        const length = (@as(u16, data[0]) << 8) | data[1];
        if (data.len < length) return error.InvalidDQT;

        var pos: usize = 2;

        while (pos < length) {
            if (pos + 1 > length) return error.InvalidDQT;

            const table_info = data[pos];
            const precision = (table_info >> 4) & 0x0F; // 0 = 8-bit, 1 = 16-bit
            const table_id = table_info & 0x0F;

            if (table_id > 3) return error.InvalidQuantTable;

            pos += 1;

            const element_size: usize = if (precision == 0) 1 else 2;
            if (pos + 64 * element_size > length) return error.InvalidDQT;

            // Read quantization table and convert from zigzag to natural order
            var table: [64]u16 = undefined;

            if (precision == 0) {
                // 8-bit values - stored in zigzag order in file, convert to natural order
                for (0..64) |i| {
                    table[zigzag_order[i]] = data[pos + i];
                }
                pos += 64;
            } else {
                // 16-bit values - stored in zigzag order in file, convert to natural order
                for (0..64) |i| {
                    table[zigzag_order[i]] = (@as(u16, data[pos + i * 2]) << 8) | data[pos + i * 2 + 1];
                }
                pos += 128;
            }

            self.quant_tables[table_id] = table;
        }
    }

    // Parse Start of Scan (SOS) marker
    pub fn parseSOS(self: *JpegDecoder, data: []const u8) !void {
        if (data.len < 6) return error.InvalidSOS;

        const length = (@as(u16, data[0]) << 8) | data[1];
        if (data.len < length) return error.InvalidSOS;

        const num_components = data[2];
        if (num_components != self.num_components) return error.InvalidSOS;

        self.scan_components = try self.allocator.alloc(ScanComponent, num_components);

        var pos: usize = 3;
        for (0..num_components) |i| {
            if (pos + 2 > length) return error.InvalidSOS;

            self.scan_components[i] = .{
                .component_id = data[pos],
                .dc_table_id = @intCast(data[pos + 1] >> 4),
                .ac_table_id = @intCast(data[pos + 1] & 0x0F),
            };

            pos += 2;
        }

        // Skip spectral selection and successive approximation (should be 0, 63, 0 for baseline)
        if (pos + 3 > length) return error.InvalidSOS;
    }

    // Parse Define Restart Interval (DRI) marker
    pub fn parseDRI(self: *JpegDecoder, data: []const u8) !void {
        if (data.len < 4) return error.InvalidDRI;

        const length = (@as(u16, data[0]) << 8) | data[1];
        if (length != 4) return error.InvalidDRI;

        self.restart_interval = (@as(u16, data[2]) << 8) | data[3];
    }

    // Decode a Huffman symbol
    pub fn decodeHuffmanSymbol(self: *JpegDecoder, table: *const HuffmanTable) !u8 {
        var code: i32 = 0;

        for (0..16) |i| {
            const bit = try self.bit_reader.getBits(1);
            code = (code << 1) | @as(i32, bit);

            if (code <= table.maxcode[i]) {
                if (table.valptr[i] == -1) return error.InvalidHuffmanCode;
                const index = @as(usize, @intCast(table.valptr[i] + (code - table.mincode[i])));
                if (index >= table.huffval.len) return error.InvalidHuffmanCode;
                return table.huffval[index];
            }
        }

        return error.InvalidHuffmanCode;
    }

    // Decode AC coefficients
    pub fn decodeAC(self: *JpegDecoder, table: *const HuffmanTable, block: *[64]i32) !void {
        var k: usize = 1; // Start after DC coefficient

        while (k < 64) {
            const symbol = try self.decodeHuffmanSymbol(table);

            if (symbol == 0) {
                // End of block
                while (k < 64) {
                    block[zigzag_order[k]] = 0;
                    k += 1;
                }
                return;
            }

            const run = symbol >> 4;
            const size = symbol & 0x0F;

            if (size == 0) {
                if (run != 15) return error.InvalidACValue;
                // Skip 16 zeros
                for (0..16) |_| {
                    if (k >= 64) return error.InvalidACValue;
                    block[zigzag_order[k]] = 0;
                    k += 1;
                }
            } else {
                // Skip 'run' zeros
                for (0..run) |_| {
                    if (k >= 64) return error.InvalidACValue;
                    block[zigzag_order[k]] = 0;
                    k += 1;
                }

                if (k >= 64) return error.InvalidACValue;

                // Decode AC value
                const bits = try self.bit_reader.getBits(@intCast(size));
                var value: i32 = @intCast(bits);

                // Convert from unsigned to signed
                if (bits < (@as(u32, 1) << @intCast(size - 1))) {
                    value = @as(i32, @intCast(bits)) - @as(i32, @intCast((@as(u32, 1) << @intCast(size)) - 1));
                }

                block[zigzag_order[k]] = value;
                k += 1;
            }
        }
    }
};

// Huffman table for decoding
const HuffmanTable = struct {
    // Number of codes for each bit length (1-16)
    bits: [16]u8,
    // Huffman values in order
    huffval: []u8,
    // Decoding tables
    mincode: [16]i32,
    maxcode: [16]i32,
    valptr: [16]i32,

    pub fn deinit(self: *HuffmanTable, allocator: Allocator) void {
        allocator.free(self.huffval);
    }
};

// Bit reader for entropy-coded segments
const BitReader = struct {
    data: []const u8,
    byte_pos: usize = 0,
    bit_pos: u3 = 0,
    bits_left: u32 = 0,
    bit_buffer: u32 = 0,

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data };
    }

    pub fn getBits(self: *BitReader, n: u5) !u16 {
        while (self.bits_left < n) {
            if (self.byte_pos >= self.data.len) return error.UnexpectedEndOfData;

            const byte = self.data[self.byte_pos];
            self.byte_pos += 1;

            // Handle 0xFF byte stuffing - 0xFF 0x00 sequence represents actual 0xFF data
            if (byte == 0xFF) {
                if (self.byte_pos >= self.data.len) return error.UnexpectedEndOfData;
                const next = self.data[self.byte_pos];
                if (next == 0x00) {
                    // This is stuffed 0xFF - skip the 0x00 and use 0xFF
                    self.byte_pos += 1;
                    // byte remains 0xFF
                } else if (next >= 0xD0 and next <= 0xD7) {
                    // Restart marker - we've consumed the FF, now consume the marker byte
                    self.byte_pos += 1;
                    // Reset bit buffer state
                    self.bit_buffer = 0;
                    self.bits_left = 0;
                    continue;
                } else {
                    // This is another marker - should not happen in entropy-coded data
                    return error.InvalidByteStuffing;
                }
            }

            self.bit_buffer = (self.bit_buffer << 8) | byte;
            self.bits_left += 8;
        }

        self.bits_left -= n;
        const result = @as(u16, @intCast((self.bit_buffer >> @intCast(self.bits_left)) & ((@as(u32, 1) << n) - 1)));
        return result;
    }
};

// Zigzag scan order for 8x8 blocks
const zigzag_order = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

// Parse JPEG file and decode image
pub fn decode(allocator: Allocator, data: []const u8) !JpegDecoder {
    var decoder = JpegDecoder.init(allocator);
    errdefer decoder.deinit();

    // Check for JPEG SOI marker
    if (data.len < 2 or data[0] != 0xFF or data[1] != 0xD8) {
        return error.InvalidJpegFile;
    }

    var pos: usize = 2;

    // Parse JPEG markers
    while (pos < data.len - 1) {
        if (data[pos] != 0xFF) {
            return error.InvalidMarker;
        }

        const marker_bytes = [2]u8{ data[pos], data[pos + 1] };
        const marker = Marker.fromBytes(marker_bytes) orelse {
            // Skip unknown markers
            pos += 2;
            if (pos + 2 > data.len) break;
            const length = (@as(u16, data[pos]) << 8) | data[pos + 1];
            if (length < 2) return error.InvalidMarker; // Invalid length
            pos += length;
            continue;
        };

        switch (marker) {
            .SOI => {
                pos += 2;
                continue; // Already handled
            },
            .EOI => break,
            .SOF0 => {
                try decoder.parseSOF(data[pos + 2 ..]);
                // parseSOF will handle advancing position internally
                const length = (@as(u16, data[pos + 2]) << 8) | data[pos + 3];
                pos += 2 + length;
            },
            .DHT => {
                try decoder.parseDHT(data[pos + 2 ..]);
                const length = (@as(u16, data[pos + 2]) << 8) | data[pos + 3];
                pos += 2 + length;
            },
            .DQT => {
                try decoder.parseDQT(data[pos + 2 ..]);
                const length = (@as(u16, data[pos + 2]) << 8) | data[pos + 3];
                pos += 2 + length;
            },
            .SOS => {
                try decoder.parseSOS(data[pos + 2 ..]);
                // After SOS, we have the entropy-coded data
                const header_len = (@as(u16, data[pos + 2]) << 8) | data[pos + 3];
                pos += 2 + header_len;

                // Find the end of entropy-coded data (next marker)
                var scan_end = pos;
                while (scan_end < data.len - 1) {
                    if (data[scan_end] == 0xFF) {
                        if (scan_end + 1 < data.len) {
                            const next_byte = data[scan_end + 1];
                            // 0xFF00 is byte stuffing, not a marker
                            if (next_byte == 0x00) {
                                scan_end += 2;
                                continue;
                            }
                            // Check if it's a restart marker (can appear in entropy data)
                            if (next_byte >= 0xD0 and next_byte <= 0xD7) {
                                scan_end += 2;
                                continue;
                            }
                            // Any other marker ends the entropy-coded segment
                            break;
                        }
                    }
                    scan_end += 1;
                }

                decoder.bit_reader = BitReader.init(data[pos..scan_end]);
                return decoder;
            },
            .DRI => {
                try decoder.parseDRI(data[pos + 2 ..]);
                const length = (@as(u16, data[pos + 2]) << 8) | data[pos + 3];
                pos += 2 + length;
            },
            .APP0, .APP1, .APP2, .APP3, .APP4, .APP5, .APP6, .APP7, .APP8, .APP9, .APP10, .APP11, .APP12, .APP13, .APP14, .APP15, .COM => {
                // Skip these markers
                if (pos + 4 > data.len) break;
                const length = (@as(u16, data[pos + 2]) << 8) | data[pos + 3];
                pos += 2 + length;
            },
            else => {
                // Skip unknown markers with length
                if (pos + 4 > data.len) break;
                const length = (@as(u16, data[pos + 2]) << 8) | data[pos + 3];
                pos += 2 + length;
            },
        }
    }

    return error.NoScanData;
}

// Error types
pub const JpegError = error{
    InvalidJpegFile,
    InvalidMarker,
    InvalidSOF,
    InvalidDHT,
    InvalidDQT,
    InvalidSOS,
    InvalidDRI,
    UnsupportedJpegFormat,
    InvalidComponentCount,
    InvalidHuffmanTable,
    InvalidQuantTable,
    NoScanData,
    UnexpectedEndOfData,
    InvalidByteStuffing,
    OutOfMemory,
    InvalidHuffmanCode,
    MissingHuffmanTable,
    MissingQuantTable,
};

// Generate Huffman decoding tables
fn generateHuffmanTables(table: *HuffmanTable) !void {
    var code: i32 = 0;
    var k: usize = 0;

    for (0..16) |i| {
        if (table.bits[i] == 0) {
            table.maxcode[i] = -1;
            table.mincode[i] = 0x7FFFFFFF;
            table.valptr[i] = -1;
        } else {
            table.valptr[i] = @intCast(k);
            table.mincode[i] = code;
            for (0..table.bits[i]) |_| {
                code += 1;
                k += 1;
            }
            table.maxcode[i] = code - 1;
        }
        code <<= 1;
    }
}

// IDCT implementation based on stb_image
fn f2f(comptime x: f32) i32 {
    // 4096 = 1 << 12
    return @intFromFloat(x * 4096 + 0.5);
}

fn idct1D(s0: i32, s1: i32, s2: i32, s3: i32, s4: i32, s5: i32, s6: i32, s7: i32) struct { i32, i32, i32, i32, i32, i32, i32, i32 } {
    var p2 = s2;
    var p3 = s6;

    var p1 = (p2 + p3) * f2f(0.5411961);
    var t2 = p1 + p3 * f2f(-1.847759065);
    var t3 = p1 + p2 * f2f(0.765366865);
    p2 = s0;
    p3 = s4;
    var t0 = (p2 + p3) * 4096;
    var t1 = (p2 - p3) * 4096;
    const x0 = t0 + t3;
    const x3 = t0 - t3;
    const x1 = t1 + t2;
    const x2 = t1 - t2;
    t0 = s7;
    t1 = s5;
    t2 = s3;
    t3 = s1;
    p3 = t0 + t2;
    var p4 = t1 + t3;
    p1 = t0 + t3;
    p2 = t1 + t2;
    const p5 = (p3 + p4) * f2f(1.175875602);
    t0 = t0 * f2f(0.298631336);
    t1 = t1 * f2f(2.053119869);
    t2 = t2 * f2f(3.072711026);
    t3 = t3 * f2f(1.501321110);
    p1 = p5 + p1 * f2f(-0.899976223);
    p2 = p5 + p2 * f2f(-2.562915447);
    p3 = p3 * f2f(-1.961570560);
    p4 = p4 * f2f(-0.390180644);
    t3 += p1 + p4;
    t2 += p2 + p3;
    t1 += p2 + p4;
    t0 += p1 + p3;

    return .{ x0, x1, x2, x3, t0, t1, t2, t3 };
}

fn idct8x8(block: *[64]i32) void {
    // Pass 1: process columns
    for (0..8) |x| {
        const s0 = block[0 * 8 + x];
        const s1 = block[1 * 8 + x];
        const s2 = block[2 * 8 + x];
        const s3 = block[3 * 8 + x];
        const s4 = block[4 * 8 + x];
        const s5 = block[5 * 8 + x];
        const s6 = block[6 * 8 + x];
        const s7 = block[7 * 8 + x];

        var x0: i32 = 0;
        var x1: i32 = 0;
        var x2: i32 = 0;
        var x3: i32 = 0;
        var t0: i32 = 0;
        var t1: i32 = 0;
        var t2: i32 = 0;
        var t3: i32 = 0;

        x0, x1, x2, x3, t0, t1, t2, t3 = idct1D(s0, s1, s2, s3, s4, s5, s6, s7);

        x0 += 512;
        x1 += 512;
        x2 += 512;
        x3 += 512;

        block[0 * 8 + x] = (x0 + t3) >> 10;
        block[1 * 8 + x] = (x1 + t2) >> 10;
        block[2 * 8 + x] = (x2 + t1) >> 10;
        block[3 * 8 + x] = (x3 + t0) >> 10;
        block[4 * 8 + x] = (x3 - t0) >> 10;
        block[5 * 8 + x] = (x2 - t1) >> 10;
        block[6 * 8 + x] = (x1 - t2) >> 10;
        block[7 * 8 + x] = (x0 - t3) >> 10;
    }

    // Pass 2: process rows
    for (0..8) |y| {
        const s0 = block[y * 8 + 0];
        const s1 = block[y * 8 + 1];
        const s2 = block[y * 8 + 2];
        const s3 = block[y * 8 + 3];
        const s4 = block[y * 8 + 4];
        const s5 = block[y * 8 + 5];
        const s6 = block[y * 8 + 6];
        const s7 = block[y * 8 + 7];

        var x0: i32 = 0;
        var x1: i32 = 0;
        var x2: i32 = 0;
        var x3: i32 = 0;
        var t0: i32 = 0;
        var t1: i32 = 0;
        var t2: i32 = 0;
        var t3: i32 = 0;

        x0, x1, x2, x3, t0, t1, t2, t3 = idct1D(s0, s1, s2, s3, s4, s5, s6, s7);

        // add 0.5 scaled up by factor
        x0 += (1 << 17) / 2;
        x1 += (1 << 17) / 2;
        x2 += (1 << 17) / 2;
        x3 += (1 << 17) / 2;

        block[y * 8 + 0] = (x0 + t3) >> 17;
        block[y * 8 + 1] = (x1 + t2) >> 17;
        block[y * 8 + 2] = (x2 + t1) >> 17;
        block[y * 8 + 3] = (x3 + t0) >> 17;
        block[y * 8 + 4] = (x3 - t0) >> 17;
        block[y * 8 + 5] = (x2 - t1) >> 17;
        block[y * 8 + 6] = (x1 - t2) >> 17;
        block[y * 8 + 7] = (x0 - t3) >> 17;
    }
}

// Upsample chroma component for 4:2:0 subsampling using bilinear interpolation
fn upsampleChroma420(input: []const [64]i32, output: *[256]i32, h_blocks: u4, v_blocks: u4, max_h: u4, max_v: u4) void {
    // For 4:2:0, input is typically 1 block (8x8), output should be max_h*8 x max_v*8
    assert(h_blocks == 1 and v_blocks == 1);
    assert(input.len == 1);

    const src_block = &input[0];
    const dst_width = @as(usize, max_h) * 8;
    const dst_height = @as(usize, max_v) * 8;
    const scale_x = 8.0 / @as(f32, @floatFromInt(dst_width));
    const scale_y = 8.0 / @as(f32, @floatFromInt(dst_height));

    // Bilinear interpolation upsampling for better quality
    for (0..dst_height) |dst_y| {
        for (0..dst_width) |dst_x| {
            // Calculate source coordinates with sub-pixel precision
            const src_x_f = (@as(f32, @floatFromInt(dst_x)) + 0.5) * scale_x - 0.5;
            const src_y_f = (@as(f32, @floatFromInt(dst_y)) + 0.5) * scale_y - 0.5;

            // Get integer and fractional parts
            const x0 = @max(0, @min(7, @as(i32, @intFromFloat(@floor(src_x_f)))));
            const y0 = @max(0, @min(7, @as(i32, @intFromFloat(@floor(src_y_f)))));
            const x1 = @min(7, x0 + 1);
            const y1 = @min(7, y0 + 1);

            const fx = src_x_f - @as(f32, @floatFromInt(x0));
            const fy = src_y_f - @as(f32, @floatFromInt(y0));

            // Get the four surrounding pixels
            const p00 = @as(f32, @floatFromInt(src_block[@as(usize, @intCast(y0)) * 8 + @as(usize, @intCast(x0))]));
            const p10 = @as(f32, @floatFromInt(src_block[@as(usize, @intCast(y0)) * 8 + @as(usize, @intCast(x1))]));
            const p01 = @as(f32, @floatFromInt(src_block[@as(usize, @intCast(y1)) * 8 + @as(usize, @intCast(x0))]));
            const p11 = @as(f32, @floatFromInt(src_block[@as(usize, @intCast(y1)) * 8 + @as(usize, @intCast(x1))]));

            // Bilinear interpolation
            const interp_x0 = p00 * (1.0 - fx) + p10 * fx;
            const interp_x1 = p01 * (1.0 - fx) + p11 * fx;
            const result = interp_x0 * (1.0 - fy) + interp_x1 * fy;

            const dst_idx = dst_y * dst_width + dst_x;
            output[dst_idx] = @intFromFloat(@round(result));
        }
    }
}

// Dequantize all blocks in storage
fn dequantizeAllBlocks(decoder: *JpegDecoder) !void {
    if (decoder.block_storage == null) return error.BlockStorageNotAllocated;

    // Apply dequantization to all blocks
    for (decoder.block_storage.?) |*block_set| {
        for (decoder.components[0..decoder.num_components], 0..) |comp, comp_idx| {
            const quant_table = decoder.quant_tables[comp.quant_table_id] orelse return error.MissingQuantTable;

            for (0..64) |i| {
                block_set[comp_idx][i] *= @as(i32, @intCast(quant_table[i]));
            }
        }
    }
}

// Apply IDCT to all blocks in storage
fn idctAllBlocks(decoder: *JpegDecoder) void {
    if (decoder.block_storage == null) return;

    // Apply IDCT to all blocks
    for (decoder.block_storage.?) |*block_set| {
        for (0..decoder.num_components) |comp_idx| {
            idct8x8(&block_set[comp_idx]);

            // Apply level shift (+128) only to Y component (component 0)
            // Cb and Cr components stay centered around 0
            if (comp_idx == 0) {
                for (0..64) |i| {
                    block_set[comp_idx][i] += 128;
                }
            }
        }
    }
}

// Convert YCbCr blocks to RGB with proper 4:2:0 chroma upsampling
fn ycbcrToRgbAllBlocks(decoder: *JpegDecoder) !void {
    if (decoder.block_storage == null) return error.BlockStorageNotAllocated;

    if (decoder.num_components == 1) {
        // Grayscale - just copy Y to all RGB channels
        for (decoder.block_storage.?, 0..) |*block_set, idx| {
            for (0..64) |i| {
                const y_val = block_set[0][i];
                const rgb_val: u8 = @intCast(std.math.clamp(y_val + 128, 0, 255));
                decoder.rgb_storage.?[idx][0][i] = rgb_val; // R
                decoder.rgb_storage.?[idx][1][i] = rgb_val; // G
                decoder.rgb_storage.?[idx][2][i] = rgb_val; // B
            }
        }
        return;
    }

    // Color with 4:2:0 chroma subsampling
    const max_h = decoder.components[0].h_sampling;
    const max_v = decoder.components[0].v_sampling;

    // Process in MCU units
    var mcu_y: usize = 0;
    while (mcu_y < decoder.block_height) : (mcu_y += max_v) {
        var mcu_x: usize = 0;
        while (mcu_x < decoder.block_width) : (mcu_x += max_h) {
            // Get the chroma block (stored at MCU origin)
            const chroma_block_index = mcu_y * decoder.block_width_actual + mcu_x;

            // Process each Y block in this MCU
            for (0..max_v) |v| {
                for (0..max_h) |h| {
                    const y_block_y = mcu_y + v;
                    const y_block_x = mcu_x + h;

                    if (y_block_y >= decoder.block_height or y_block_x >= decoder.block_width) continue;

                    const y_block_index = y_block_y * decoder.block_width_actual + y_block_x;

                    // Convert this Y block using upsampled chroma
                    for (0..64) |pixel_idx| {
                        const py = pixel_idx / 8;
                        const px = pixel_idx % 8;

                        const Y = decoder.block_storage.?[y_block_index][0][pixel_idx];

                        // Bilinear interpolation for chroma upsampling
                        const chroma_y_f = (@as(f32, @floatFromInt(v * 8 + py)) + 0.5) * 0.5 - 0.5;
                        const chroma_x_f = (@as(f32, @floatFromInt(h * 8 + px)) + 0.5) * 0.5 - 0.5;

                        const cy0 = @max(0, @min(7, @as(i32, @intFromFloat(@floor(chroma_y_f)))));
                        const cx0 = @max(0, @min(7, @as(i32, @intFromFloat(@floor(chroma_x_f)))));
                        const cy1 = @min(7, cy0 + 1);
                        const cx1 = @min(7, cx0 + 1);

                        const fy = chroma_y_f - @as(f32, @floatFromInt(cy0));
                        const fx = chroma_x_f - @as(f32, @floatFromInt(cx0));

                        // Get the four surrounding chroma values for Cb
                        const cb00 = @as(f32, @floatFromInt(decoder.block_storage.?[chroma_block_index][1][@as(usize, @intCast(cy0)) * 8 + @as(usize, @intCast(cx0))]));
                        const cb10 = @as(f32, @floatFromInt(decoder.block_storage.?[chroma_block_index][1][@as(usize, @intCast(cy0)) * 8 + @as(usize, @intCast(cx1))]));
                        const cb01 = @as(f32, @floatFromInt(decoder.block_storage.?[chroma_block_index][1][@as(usize, @intCast(cy1)) * 8 + @as(usize, @intCast(cx0))]));
                        const cb11 = @as(f32, @floatFromInt(decoder.block_storage.?[chroma_block_index][1][@as(usize, @intCast(cy1)) * 8 + @as(usize, @intCast(cx1))]));

                        // Get the four surrounding chroma values for Cr
                        const cr00 = @as(f32, @floatFromInt(decoder.block_storage.?[chroma_block_index][2][@as(usize, @intCast(cy0)) * 8 + @as(usize, @intCast(cx0))]));
                        const cr10 = @as(f32, @floatFromInt(decoder.block_storage.?[chroma_block_index][2][@as(usize, @intCast(cy0)) * 8 + @as(usize, @intCast(cx1))]));
                        const cr01 = @as(f32, @floatFromInt(decoder.block_storage.?[chroma_block_index][2][@as(usize, @intCast(cy1)) * 8 + @as(usize, @intCast(cx0))]));
                        const cr11 = @as(f32, @floatFromInt(decoder.block_storage.?[chroma_block_index][2][@as(usize, @intCast(cy1)) * 8 + @as(usize, @intCast(cx1))]));

                        // Bilinear interpolation
                        const cb_interp_x0 = cb00 * (1.0 - fx) + cb10 * fx;
                        const cb_interp_x1 = cb01 * (1.0 - fx) + cb11 * fx;
                        const Cb = @as(i32, @intFromFloat(@round(cb_interp_x0 * (1.0 - fy) + cb_interp_x1 * fy)));

                        const cr_interp_x0 = cr00 * (1.0 - fx) + cr10 * fx;
                        const cr_interp_x1 = cr01 * (1.0 - fx) + cr11 * fx;
                        const Cr = @as(i32, @intFromFloat(@round(cr_interp_x0 * (1.0 - fy) + cr_interp_x1 * fy)));

                        // Convert JPEG YCbCr to Wikipedia standard - try without Y offset since image is too bright
                        const ycbcr: Ycbcr = .{ .y = @as(f32, @floatFromInt(Y)), .cb = @as(f32, @floatFromInt(Cb + 128)), .cr = @as(f32, @floatFromInt(Cr + 128)) };
                        const rgb = ycbcr.toRgb();

                        // Store RGB in separate storage to avoid overwriting chroma data
                        decoder.rgb_storage.?[y_block_index][0][pixel_idx] = rgb.r;
                        decoder.rgb_storage.?[y_block_index][1][pixel_idx] = rgb.g;
                        decoder.rgb_storage.?[y_block_index][2][pixel_idx] = rgb.b;
                    }
                }
            }
        }
    }
}

// Render RGB blocks to pixels (simple after YCbCr conversion)
fn renderRgbBlocksToPixels(comptime T: type, decoder: *JpegDecoder, img: *Image(T)) !void {
    if (decoder.rgb_storage == null) return error.RgbStorageNotAllocated;

    // Simple rendering - read from RGB storage
    var block_y: usize = 0;
    while (block_y < decoder.block_height) : (block_y += 1) {
        const pixel_y = block_y * 8;

        var block_x: usize = 0;
        while (block_x < decoder.block_width) : (block_x += 1) {
            const block_index = block_y * decoder.block_width_actual + block_x;
            const pixel_x = block_x * 8;

            for (0..8) |y| {
                for (0..8) |x| {
                    if (pixel_y + y >= decoder.height or pixel_x + x >= decoder.width) {
                        continue;
                    }

                    const pixel_idx = y * 8 + x;
                    const r = decoder.rgb_storage.?[block_index][0][pixel_idx];
                    const g = decoder.rgb_storage.?[block_index][1][pixel_idx];
                    const b = decoder.rgb_storage.?[block_index][2][pixel_idx];

                    const rgb = Rgb{ .r = r, .g = g, .b = b };
                    img.at(pixel_y + y, pixel_x + x).* = convertColor(T, rgb);
                }
            }
        }
    }
}

// Load JPEG file
pub fn loadJpeg(comptime T: type, allocator: Allocator, file_path: []const u8) !Image(T) {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const data = try allocator.alloc(u8, file_size);
    defer allocator.free(data);

    _ = try file.read(data);

    var decoder = try decode(allocator, data);
    defer decoder.deinit();

    // Create output image
    var img = try Image(T).initAlloc(allocator, decoder.height, decoder.width);

    // Complete block-based pipeline:
    // Step 1: Decode all blocks into storage
    try performBlockScan(&decoder);

    // Step 2: Apply dequantization to all blocks
    try dequantizeAllBlocks(&decoder);

    // Step 3: Apply IDCT to all blocks
    idctAllBlocks(&decoder);

    // Step 4: Convert YCbCr to RGB with proper chroma upsampling
    try ycbcrToRgbAllBlocks(&decoder);

    // Step 5: Render RGB blocks to pixels
    try renderRgbBlocksToPixels(T, &decoder, &img);

    return img;
}

// Block scan function that fills block storage
fn performBlockScan(decoder: *JpegDecoder) !void {
    if (decoder.block_storage == null) return error.BlockStorageNotAllocated;

    // Calculate maximum sampling factors
    var max_h_factor: u4 = 1;
    var max_v_factor: u4 = 1;
    for (decoder.components[0..decoder.num_components]) |comp| {
        max_h_factor = @max(max_h_factor, comp.h_sampling);
        max_v_factor = @max(max_v_factor, comp.v_sampling);
    }

    // Scan structure
    const noninterleaved = decoder.scan_components.len == 1 and decoder.scan_components[0].component_id == 1;
    const y_step = if (noninterleaved) 1 else max_v_factor;
    const x_step = if (noninterleaved) 1 else max_h_factor;

    // DC prediction values for each component
    var prediction_values = [_]i32{0} ** 4;

    var y: usize = 0;
    while (y < decoder.block_height) : (y += y_step) {
        var x: usize = 0;
        while (x < decoder.block_width) : (x += x_step) {
            // Decode each component at this position
            for (decoder.scan_components) |scan_comp| {
                // Find the component index for this scan component
                var component_index: usize = 0;
                var v_max: usize = undefined;
                var h_max: usize = undefined;

                for (decoder.components[0..decoder.num_components], 0..) |frame_component, i| {
                    if (frame_component.id == scan_comp.component_id) {
                        component_index = i;
                        v_max = if (noninterleaved) 1 else frame_component.v_sampling;
                        h_max = if (noninterleaved) 1 else frame_component.h_sampling;
                        break;
                    }
                }

                // Decode all blocks for this component in this MCU
                for (0..v_max) |v| {
                    for (0..h_max) |h| {
                        if (y + v >= decoder.block_height or x + h >= decoder.block_width) continue;

                        const block_id = (y + v) * decoder.block_width_actual + (x + h);
                        const block = &decoder.block_storage.?[block_id][component_index];

                        // Decode block directly into storage
                        try decodeBlockToStorage(decoder, scan_comp, block, &prediction_values[component_index]);
                    }
                }
            }
        }
    }
}

// Decode a single block directly into block storage
fn decodeBlockToStorage(decoder: *JpegDecoder, scan_comp: ScanComponent, block: *[64]i32, dc_prediction: *i32) !void {
    // Clear the block
    @memset(block, 0);

    // Decode DC coefficient
    const dc_table = decoder.dc_tables[scan_comp.dc_table_id] orelse return error.MissingHuffmanTable;
    const dc_symbol = try decoder.decodeHuffmanSymbol(&dc_table);

    if (dc_symbol > 11) return error.InvalidDCCoefficient;

    var dc_diff: i32 = 0;
    if (dc_symbol > 0) {
        const dc_bits = try decoder.bit_reader.getBits(@intCast(dc_symbol));
        dc_diff = @intCast(dc_bits);

        // Convert from unsigned to signed
        if (dc_bits < (@as(u32, 1) << @intCast(dc_symbol - 1))) {
            dc_diff = @as(i32, @intCast(dc_bits)) - @as(i32, @intCast((@as(u32, 1) << @intCast(dc_symbol)) - 1));
        }
    }

    dc_prediction.* += dc_diff;
    block[0] = dc_prediction.*;

    // Decode AC coefficients
    const ac_table = decoder.ac_tables[scan_comp.ac_table_id] orelse return error.MissingHuffmanTable;
    var k: usize = 1;

    while (k < 64) {
        const ac_symbol = try decoder.decodeHuffmanSymbol(&ac_table);

        if (ac_symbol == 0x00) {
            // End of block
            break;
        }

        if (ac_symbol == 0xF0) {
            // ZRL - 16 zeros
            k += 16;
            continue;
        }

        const zero_run = ac_symbol >> 4;
        const coeff_bits = ac_symbol & 0x0F;

        if (coeff_bits == 0) return error.InvalidACCoefficient;

        k += zero_run;
        if (k >= 64) break;

        const ac_bits = try decoder.bit_reader.getBits(@intCast(coeff_bits));
        var ac_value: i32 = @intCast(ac_bits);

        // Convert from unsigned to signed
        if (ac_bits < (@as(u32, 1) << @intCast(coeff_bits - 1))) {
            ac_value = @as(i32, @intCast(ac_bits)) - @as(i32, @intCast((@as(u32, 1) << @intCast(coeff_bits)) - 1));
        }

        block[zigzag_order[k]] = ac_value;
        k += 1;
    }
}

// Basic tests
test "JPEG marker parsing" {
    const testing = std.testing;

    // Test marker conversion
    const soi_bytes = [2]u8{ 0xFF, 0xD8 };
    const soi = Marker.fromBytes(soi_bytes);
    try testing.expect(soi == .SOI);

    const sof0_bytes = [2]u8{ 0xFF, 0xC0 };
    const sof0 = Marker.fromBytes(sof0_bytes);
    try testing.expect(sof0 == .SOF0);
}

test "BitReader basic operations" {
    const testing = std.testing;

    const data = [_]u8{ 0b10110011, 0b01010101 };
    var reader = BitReader.init(&data);

    // Read first 4 bits
    const bits1 = try reader.getBits(4);
    try testing.expectEqual(@as(u16, 0b1011), bits1);

    // Read next 4 bits
    const bits2 = try reader.getBits(4);
    try testing.expectEqual(@as(u16, 0b0011), bits2);

    // Read next 8 bits
    const bits3 = try reader.getBits(8);
    try testing.expectEqual(@as(u16, 0b01010101), bits3);
}

test "Ycbcr to RGB conversion" {
    const testing = std.testing;

    // Test grayscale - standard Y=128
    const gray_ycbcr: Ycbcr = .{ .y = 128, .cb = 128, .cr = 128 };
    const gray = gray_ycbcr.toRgb();
    try testing.expectEqual(@as(u8, 128), gray.r);
    try testing.expectEqual(@as(u8, 128), gray.g);
    try testing.expectEqual(@as(u8, 128), gray.b);

    // Test white - standard Y=255
    const white_ycbcr: Ycbcr = .{ .y = 255, .cb = 128, .cr = 128 };
    const white = white_ycbcr.toRgb();
    try testing.expectEqual(@as(u8, 255), white.r);
    try testing.expectEqual(@as(u8, 255), white.g);
    try testing.expectEqual(@as(u8, 255), white.b);

    // Test black - standard Y=0
    const black_ycbcr: Ycbcr = .{ .y = 0, .cb = 128, .cr = 128 };
    const black = black_ycbcr.toRgb();
    try testing.expectEqual(@as(u8, 0), black.r);
    try testing.expectEqual(@as(u8, 0), black.g);
    try testing.expectEqual(@as(u8, 0), black.b);
}

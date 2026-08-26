//! sfnt parsing for `VectorFont`: TrueType (`glyf` outlines) and CFF-flavored
//! OpenType (`OTTO`, `CFF ` outlines), standalone or inside a `ttcf` collection.
//!
//! Supported: table directory, `head`, `maxp`, `hhea`/`hmtx`, `post`, `OS/2`,
//! `cmap` formats 4 and 12, `loca`/`glyf` simple and composite glyphs, `CFF `
//! Type 2 charstrings (plain and CID-keyed, `seac` accents), kerning from the
//! legacy `kern` table and from GPOS pair adjustment.
//! Variable fonts render their default instance; for another weight or width, make a
//! static instance (`fonttools varLib.instancer`) and load that. Not supported: hinting,
//! variation axes, color fonts, GSUB, mark attachment.

const std = @import("std");

const VectorFont = @import("VectorFont.zig");

const reader = @import("truetype/reader.zig");
pub const Reader = reader.Reader;
pub const Table = reader.Table;
pub const cmap = @import("truetype/cmap.zig");
pub const glyf = @import("truetype/glyf.zig");
pub const kern = @import("truetype/kern.zig");
pub const gpos = @import("truetype/gpos.zig");
pub const cff = @import("truetype/cff.zig");

pub const Error = error{
    /// Bad sfnt tag, table directory, table record, or a face index past the collection.
    InvalidFormat,
    /// CFF charstrings that are not Type 2, or a CFF2 table of another major version.
    UnsupportedFontFormat,
    /// A read past the end of the data.
    UnexpectedEof,
    /// A required table (`head`, `maxp`, `hhea`, `hmtx`, `cmap`, and `loca`/`glyf` or
    /// `CFF `/`CFF2` with its CharStrings and Private DICT) is absent.
    MissingTable,
    /// No Unicode `cmap` subtable in format 4 or 12.
    UnsupportedCmap,
    /// Bad glyph index, malformed glyph record or charstring.
    InvalidGlyph,
    /// Composite glyph nesting or fan-out beyond the limits.
    CompositeTooDeep,
    /// More points or contours than an outline may hold.
    TooManyPoints,
};

const max_tables = 512;

pub const IndexToLocFormat = enum(u1) { short, long };

/// The table(s) holding glyph outlines.
pub const Outlines = union(enum) {
    glyf: Glyf,
    cff: cff.Font,

    pub const Glyf = struct {
        loca: Table,
        glyf: Table,
        index_to_loc_format: IndexToLocFormat,
    };
};

/// Where the per-glyph data lives; the fixed-size header tables are folded into
/// `VectorFont`'s fields at load time.
pub const Tables = struct {
    outlines: Outlines,
    hmtx: Table,
    cmap: Table,
    kern: ?Table = null,
    /// Present only when it holds pair adjustment; it then takes precedence over `kern`.
    gpos: ?gpos.PairPos = null,
};

pub const sfnt_true_type: u32 = 0x00010000;
const sfnt_apple = tag("true");
pub const sfnt_cff = tag("OTTO");
const sfnt_collection = tag("ttcf");

fn tag(comptime name: *const [4]u8) u32 {
    return std.mem.readInt(u32, name, .big);
}

const Tag = struct {
    const head = tag("head");
    const maxp = tag("maxp");
    const hhea = tag("hhea");
    const hmtx = tag("hmtx");
    const cmap = tag("cmap");
    const loca = tag("loca");
    const glyf = tag("glyf");
    const post = tag("post");
    const os2 = tag("OS/2");
    const kern = tag("kern");
    const gpos = tag("GPOS");
    const cff = tag("CFF ");
    const cff2 = tag("CFF2");
};

/// Parses the header tables of `data` and validates the ones `VectorFont` reads later.
/// Borrows `data`; nothing is allocated. Collections yield their first face.
pub fn parse(data: []const u8) Error!VectorFont {
    return parseFace(data, 0);
}

/// `parse` for face `face` of a `ttcf` collection; a single font has only face 0.
pub fn parseFace(data: []const u8, face: u32) Error!VectorFont {
    const r: Reader = .init(data);
    var num_faces: u32 = 1;
    var dir: u32 = 0;
    if (try r.u32At(0) == sfnt_collection) {
        num_faces = try r.u32At(8);
        if (face >= num_faces) return error.InvalidFormat;
        dir = try r.u32At(12 + 4 * @as(usize, face));
    } else if (face != 0) return error.InvalidFormat;
    const has_cff = switch (try r.u32At(dir)) {
        sfnt_true_type, sfnt_apple => false,
        sfnt_cff => true,
        else => return error.InvalidFormat,
    };

    var head: ?Table = null;
    var maxp: ?Table = null;
    var hhea: ?Table = null;
    var hmtx: ?Table = null;
    var cmap_table: ?Table = null;
    var loca: ?Table = null;
    var glyf_table: ?Table = null;
    var post: ?Table = null;
    var os2: ?Table = null;
    var kern_table: ?Table = null;
    var gpos_table: ?Table = null;
    var cff_table: ?Table = null;
    var cff2_table: ?Table = null;

    const num_tables = try r.u16At(dir + 4);
    if (num_tables > max_tables) return error.InvalidFormat;
    for (0..num_tables) |i| {
        const rec = dir + 12 + i * 16;
        const table: Table = .{ .offset = try r.u32At(rec + 8), .len = try r.u32At(rec + 12) };
        const end = @as(u64, table.offset) + table.len;
        if (end > data.len) return error.InvalidFormat;
        switch (try r.u32At(rec)) {
            Tag.head => head = table,
            Tag.maxp => maxp = table,
            Tag.hhea => hhea = table,
            Tag.hmtx => hmtx = table,
            Tag.cmap => cmap_table = table,
            Tag.loca => loca = table,
            Tag.glyf => glyf_table = table,
            Tag.post => post = table,
            Tag.os2 => os2 = table,
            Tag.kern => kern_table = table,
            Tag.gpos => gpos_table = table,
            Tag.cff => cff_table = table,
            Tag.cff2 => cff2_table = table,
            else => {},
        }
    }

    const head_r = r.table(head orelse return error.MissingTable);
    const units_per_em = try head_r.u16At(18);
    if (units_per_em == 0) return error.InvalidFormat;
    const flags = try head_r.u16At(16);

    const num_glyphs = try r.table(maxp orelse return error.MissingTable).u16At(4);

    const hhea_r = r.table(hhea orelse return error.MissingTable);
    var ascent = try hhea_r.i16At(4);
    var descent = try hhea_r.i16At(6);
    var line_gap = try hhea_r.i16At(8);
    const advance_width_max = try hhea_r.u16At(10);
    const num_h_metrics = try hhea_r.u16At(34);
    if (num_h_metrics == 0 or num_h_metrics > num_glyphs) return error.InvalidFormat;

    const hmtx_t = hmtx orelse return error.MissingTable;
    if (hmtx_t.len < 4 * @as(u32, num_h_metrics) + 2 * @as(u32, num_glyphs - num_h_metrics)) return error.InvalidFormat;

    const outlines: Outlines = if (has_cff) .{
        .cff = if (cff_table) |t|
            try cff.parse(t, r, num_glyphs)
        else if (cff2_table) |t|
            try cff.parse2(t, r, num_glyphs)
        else
            return error.MissingTable,
    } else glyf_outlines: {
        const index_to_loc_format: IndexToLocFormat = switch (try head_r.i16At(50)) {
            0 => .short,
            1 => .long,
            else => return error.InvalidFormat,
        };
        const loca_t = loca orelse return error.MissingTable;
        const loca_entry: u32 = switch (index_to_loc_format) {
            .short => 2,
            .long => 4,
        };
        if (loca_t.len < (@as(u32, num_glyphs) + 1) * loca_entry) return error.InvalidFormat;
        break :glyf_outlines .{ .glyf = .{
            .loca = loca_t,
            .glyf = glyf_table orelse return error.MissingTable,
            .index_to_loc_format = index_to_loc_format,
        } };
    };

    var underline_position: i16 = 0;
    var underline_thickness: i16 = @intCast(units_per_em / 20);
    if (post) |t| {
        const post_r = r.table(t);
        underline_position = try post_r.i16At(8);
        underline_thickness = try post_r.i16At(10);
    }

    var strikeout_size = underline_thickness;
    var strikeout_position = @divTrunc(ascent, 2);
    if (os2) |t| {
        if (t.len >= 78) {
            const os2_r = r.table(t);
            strikeout_size = try os2_r.i16At(26);
            strikeout_position = try os2_r.i16At(28);
            // FreeType's rule: hhea metrics win unless they are all zero.
            if (ascent == 0 and descent == 0 and line_gap == 0) {
                ascent = try os2_r.i16At(68);
                descent = try os2_r.i16At(70);
                line_gap = try os2_r.i16At(72);
            }
        }
    }

    const cmap_t = cmap_table orelse return error.MissingTable;
    const cmap_subtable = try cmap.select(r.table(cmap_t));

    return .{
        .data = data,
        .num_faces = num_faces,
        .units_per_em = units_per_em,
        .num_glyphs = num_glyphs,
        .num_h_metrics = num_h_metrics,
        .lsb_is_at_x_zero = flags & 0x2 != 0,
        .ascent = ascent,
        .descent = descent,
        .line_gap = line_gap,
        .advance_width_max = advance_width_max,
        .underline_position = underline_position,
        .underline_thickness = underline_thickness,
        .strikeout_size = strikeout_size,
        .strikeout_position = strikeout_position,
        .tables = .{
            .outlines = outlines,
            .hmtx = hmtx_t,
            .cmap = cmap_t,
            .kern = kern_table,
            // A GPOS without pair adjustment has nothing this parser reads.
            .gpos = if (gpos_table) |t| try gpos.findPairPos(r.table(t), t) else null,
        },
        .cmap = cmap_subtable,
    };
}

test {
    _ = reader;
    _ = cmap;
    _ = glyf;
    _ = kern;
    _ = gpos;
    _ = cff;
    _ = @import("truetype/synthetic.zig");
}

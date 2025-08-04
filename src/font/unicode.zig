//! Unicode range utilities for font loading
//!
//! This module provides common Unicode ranges and utilities for specifying
//! which characters to load from font files.

/// A Unicode character range
pub const Range = struct {
    start: u21,
    end: u21,
};

/// Common Unicode ranges for convenience
pub const ranges = struct {
    /// Basic Latin (ASCII)
    pub const ascii = Range{ .start = 0x0000, .end = 0x007F };
    /// Latin-1 Supplement
    pub const latin1_supplement = Range{ .start = 0x0080, .end = 0x00FF };
    /// Full Latin-1 (ASCII + Latin-1 Supplement)
    pub const latin1 = Range{ .start = 0x0000, .end = 0x00FF };
    /// Greek and Coptic
    pub const greek = Range{ .start = 0x0370, .end = 0x03FF };
    /// Cyrillic
    pub const cyrillic = Range{ .start = 0x0400, .end = 0x04FF };
    /// Arabic
    pub const arabic = Range{ .start = 0x0600, .end = 0x06FF };
    /// Hebrew
    pub const hebrew = Range{ .start = 0x0590, .end = 0x05FF };
    /// Hiragana
    pub const hiragana = Range{ .start = 0x3040, .end = 0x309F };
    /// Katakana
    pub const katakana = Range{ .start = 0x30A0, .end = 0x30FF };
    /// CJK Unified Ideographs (main block)
    pub const cjk_unified = Range{ .start = 0x4E00, .end = 0x9FFF };
    /// Hangul Syllables (Korean)
    pub const hangul = Range{ .start = 0xAC00, .end = 0xD7AF };
    /// Emoji & Pictographs
    pub const emoji = Range{ .start = 0x1F300, .end = 0x1F9FF };
    /// Mathematical Operators
    pub const math = Range{ .start = 0x2200, .end = 0x22FF };
    /// Box Drawing
    pub const box_drawing = Range{ .start = 0x2500, .end = 0x257F };
    /// Block Elements
    pub const block_elements = Range{ .start = 0x2580, .end = 0x259F };
    /// CJK Symbols and Punctuation
    pub const cjk_punctuation = Range{ .start = 0x3000, .end = 0x303F };
    /// Common Western European languages (Latin-1 + Latin Extended-A)
    pub const western_european = [_]Range{
        latin1,
        Range{ .start = 0x0100, .end = 0x017F }, // Latin Extended-A
    };
    /// Common East Asian languages
    pub const east_asian = [_]Range{
        hiragana,
        katakana,
        cjk_unified,
        hangul,
    };
    /// Chinese (both simplified and traditional)
    pub const chinese = [_]Range{
        cjk_unified,
        cjk_punctuation,
    };
    /// Japanese writing systems (hiragana, katakana, kanji)
    pub const japanese = [_]Range{
        hiragana,
        katakana,
        cjk_unified,
        cjk_punctuation,
    };

    /// Korean (Hangul + punctuation)
    pub const korean = [_]Range{
        hangul,
        cjk_punctuation,
    };
};

const std = @import("std");

pub const js = struct {
    extern "js" fn log(ptr: [*]const u8, len: usize) void;
    extern "js" fn now() i32;
};

pub fn nowFn() f32 {
    return @floatFromInt(js.now());
}

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime message_level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    var buf: [500]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, level_txt ++ prefix2 ++ format, args) catch l: {
        buf[buf.len - 3 ..][0..3].* = "...".*;
        break :l &buf;
    };
    js.log(line.ptr, line.len);
}

export fn alloc(len: usize) [*]u8 {
    const slice = std.heap.wasm_allocator.alloc(u8, len) catch @panic("OOM");
    return slice.ptr;
}

export fn free(ptr: [*]const u8, len: usize) void {
    std.heap.wasm_allocator.free(ptr[0..len]);
}

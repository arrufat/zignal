/// Converts between numeric types: .Enum, .Int and .Float.
pub inline fn as(comptime T: type, from: anytype) T {
    switch (@typeInfo(@TypeOf(from))) {
        .Enum => {
            switch (@typeInfo(T)) {
                .Int => return @intFromEnum(from),
                else => @compileError(@typeName(@TypeOf(from)) ++ " can't be converted to " ++ @typeName(T)),
            }
        },
        .Int => {
            switch (@typeInfo(T)) {
                .Enum => return @enumFromInt(from),
                .Int => return @intCast(from),
                .Float => return @floatFromInt(from),
                else => @compileError(@typeName(@TypeOf(from)) ++ " can't be converted to " ++ @typeName(T)),
            }
        },
        .Float => {
            switch (@typeInfo(T)) {
                .Float => return @floatCast(from),
                .Int => return @intFromFloat(from),
                else => @compileError(@typeName(@TypeOf(from)) ++ " can't be converted to " ++ @typeName(T)),
            }
        },
        else => @compileError(@typeName(@TypeOf(from) ++ " is not supported.")),
    }
}

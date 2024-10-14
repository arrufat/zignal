const std = @import("std");
const builtin = @import("builtin");

pub const std_options: std.Options = .{
    .logFn = if (builtin.cpu.arch.isWasm()) @import("js.zig").logFn else std.log.defaultLog,
    .log_level = std.log.default_level,
};

const convert = @import("zignal").colorspace.convert;
const Rgb = @import("zignal").Rgb;
const Hsl = @import("zignal").Hsl;
const Hsv = @import("zignal").Hsv;
const Xyz = @import("zignal").Xyz;
const Lab = @import("zignal").Lab;

// --- RGB ---

export fn rgb2hsl(red: u8, green: u8, blue: u8, out: [*]f32) void {
    const res = convert(Hsl, Rgb{ .r = red, .g = green, .b = blue });
    std.log.debug("HSL: {[h]d} {[s]d} {[l]d}", res);
    out[0] = res.h;
    out[1] = res.s;
    out[2] = res.l;
}

export fn rgb2hsv(red: u8, green: u8, blue: u8, out: [*]f32) void {
    const res = convert(Hsv, Rgb{ .r = red, .g = green, .b = blue });
    std.log.debug("HSV: {[h]d} {[s]d} {[v]d}", res);
    out[0] = res.h;
    out[1] = res.s;
    out[2] = res.v;
}
export fn rgb2xyz(red: u8, green: u8, blue: u8, out: [*]f32) void {
    const res = convert(Xyz, Rgb{ .r = red, .g = green, .b = blue });
    std.log.debug("XYZ: {[x]d} {[y]d} {[z]d}", res);
    out[0] = @floatCast(res.x);
    out[1] = @floatCast(res.y);
    out[2] = @floatCast(res.z);
}
export fn rgb2lab(red: u8, green: u8, blue: u8, out: [*]f32) void {
    const res = convert(Lab, Rgb{ .r = red, .g = green, .b = blue });
    std.log.debug("LAB: {[l]d} {[a]d} {[b]d}", res);
    out[0] = @floatCast(res.l);
    out[1] = @floatCast(res.a);
    out[2] = @floatCast(res.b);
}

// --- HSL ---

export fn hsl2rgb(h: f32, s: f32, l: f32, out: [*]u8) void {
    const res = convert(Rgb, Hsl{ .h = h, .s = s, .l = l });
    std.log.debug("RGB: {[r]d} {[g]d} {[b]d}", res);
    out[0] = res.r;
    out[1] = res.g;
    out[2] = res.b;
}

export fn hsl2hsv(h: f32, s: f32, l: f32, out: [*]f32) void {
    const res = convert(Hsv, Hsl{ .h = h, .s = s, .l = l });
    std.log.debug("HSV: {[h]d} {[s]d} {[v]d}", res);
    out[0] = res.h;
    out[1] = res.s;
    out[2] = res.v;
}

export fn hsl2xyz(h: f32, s: f32, l: f32, out: [*]f32) void {
    const res = convert(Xyz, Hsl{ .h = h, .s = s, .l = l });
    std.log.debug("XYZ: {[x]d} {[y]d} {[z]d}", res);
    out[0] = @floatCast(res.x);
    out[1] = @floatCast(res.y);
    out[2] = @floatCast(res.z);
}

export fn hsl2lab(h: f32, s: f32, l: f32, out: [*]f32) void {
    const res = convert(Lab, Hsl{ .h = h, .s = s, .l = l });
    std.log.debug("LAB: {[l]d} {[a]d} {[b]d}", res);
    out[0] = @floatCast(res.l);
    out[1] = @floatCast(res.a);
    out[2] = @floatCast(res.b);
}

// --- HSV ---

export fn hsv2rgb(h: f32, s: f32, v: f32, out: [*]u8) void {
    const res = convert(Rgb, Hsv{ .h = h, .s = s, .v = v });
    std.log.debug("RGB: {[r]d} {[g]d} {[b]d}", res);
    out[0] = res.r;
    out[1] = res.g;
    out[2] = res.b;
}

export fn hsv2hsl(h: f32, s: f32, v: f32, out: [*]f32) void {
    const res = convert(Hsl, Hsv{ .h = h, .s = s, .v = v });
    std.log.debug("HSL: {[h]d} {[s]d} {[l]d}", res);
    out[0] = res.h;
    out[1] = res.s;
    out[2] = res.l;
}

export fn hsv2xyz(h: f32, s: f32, v: f32, out: [*]f32) void {
    const res = convert(Xyz, Hsv{ .h = h, .s = s, .v = v });
    std.log.debug("XYZ: {[x]d} {[y]d} {[z]d}", res);
    out[0] = @floatCast(res.x);
    out[1] = @floatCast(res.y);
    out[2] = @floatCast(res.z);
}

export fn hsv2lab(h: f32, s: f32, v: f32, out: [*]f32) void {
    const res = convert(Lab, Hsv{ .h = h, .s = s, .v = v });
    std.log.debug("LAB: {[l]d} {[a]d} {[b]d}", res);
    out[0] = @floatCast(res.l);
    out[1] = @floatCast(res.a);
    out[2] = @floatCast(res.b);
}

// --- XYZ ---

export fn xyz2rgb(x: f32, y: f32, z: f32, out: [*]u8) void {
    const res = convert(Rgb, Xyz{ .x = x, .y = y, .z = z });
    std.log.debug("RGB: {[r]d} {[g]d} {[b]d}", res);
    out[0] = res.r;
    out[1] = res.g;
    out[2] = res.b;
}

export fn xyz2hsl(x: f32, y: f32, z: f32, out: [*]f32) void {
    const res = convert(Hsl, Xyz{ .x = x, .y = y, .z = z });
    std.log.debug("HSL: {[h]d} {[s]d} {[l]d}", res);
    out[0] = res.h;
    out[1] = res.s;
    out[2] = res.l;
}

export fn xyz2hsv(x: f32, y: f32, z: f32, out: [*]f32) void {
    const res = convert(Hsv, Xyz{ .x = x, .y = y, .z = z });
    std.log.debug("HSV: {[h]d} {[s]d} {[v]d}", res);
    out[0] = res.h;
    out[1] = res.s;
    out[2] = res.v;
}

export fn xyz2lab(x: f32, y: f32, z: f32, out: [*]f32) void {
    const res = convert(Lab, Xyz{ .x = x, .y = y, .z = z });
    std.log.debug("LAB: {[l]d} {[a]d} {[b]d}", res);
    out[0] = @floatCast(res.l);
    out[1] = @floatCast(res.a);
    out[2] = @floatCast(res.b);
}

// --- LAB ---

export fn lab2rgb(l: f32, a: f32, b: f32, out: [*]u8) void {
    const res = convert(Rgb, Lab{ .l = l, .a = a, .b = b });
    std.log.debug("RGB: {[r]d} {[g]d} {[b]d}", res);
    out[0] = res.r;
    out[1] = res.g;
    out[2] = res.b;
}

export fn lab2hsl(l: f32, a: f32, b: f32, out: [*]f32) void {
    const res = convert(Hsl, Lab{ .l = l, .a = a, .b = b });
    std.log.debug("HSL: {[h]d} {[s]d} {[l]d}", res);
    out[0] = res.h;
    out[1] = res.s;
    out[2] = res.l;
}

export fn lab2hsv(l: f32, a: f32, b: f32, out: [*]f32) void {
    const res = convert(Hsv, Lab{ .l = l, .a = a, .b = b });
    std.log.debug("HSV: {[h]d} {[s]d} {[v]d}", res);
    out[0] = res.h;
    out[1] = res.s;
    out[2] = res.v;
}

export fn lab2xyz(l: f32, a: f32, b: f32, out: [*]f32) void {
    const res = convert(Xyz, Lab{ .l = l, .a = a, .b = b });
    std.log.debug("XYZ: {[x]d} {[y]d} {[z]d}", res);
    out[0] = @floatCast(res.x);
    out[1] = @floatCast(res.y);
    out[2] = @floatCast(res.z);
}

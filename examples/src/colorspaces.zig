const std = @import("std");
const builtin = @import("builtin");

const convertColor = @import("zignal").convertColor;
const Hsl = @import("zignal").Hsl;
const Hsv = @import("zignal").Hsv;
const Lab = @import("zignal").Lab;
const Lms = @import("zignal").Lms;
const Oklab = @import("zignal").Oklab;
const Oklch = @import("zignal").Oklch;
const Rgb = @import("zignal").Rgb;
const Xyb = @import("zignal").Xyb;
const Xyz = @import("zignal").Xyz;
const Ycbcr = @import("zignal").Ycbcr;

pub const std_options: std.Options = .{
    .logFn = if (builtin.cpu.arch.isWasm()) @import("js.zig").logFn else std.log.defaultLog,
    .log_level = std.log.default_level,
};

// --- RGB ---

export fn rgb2hsl(red: u8, green: u8, blue: u8, out: [*]f64) void {
    const res = convertColor(Hsl, Rgb{ .r = red, .g = green, .b = blue });
    std.log.debug("HSL: {[h]d} {[s]d} {[l]d}", res);
    out[0] = res.h;
    out[1] = res.s;
    out[2] = res.l;
}

export fn rgb2hsv(red: u8, green: u8, blue: u8, out: [*]f64) void {
    const res = convertColor(Hsv, Rgb{ .r = red, .g = green, .b = blue });
    std.log.debug("HSV: {[h]d} {[s]d} {[v]d}", res);
    out[0] = res.h;
    out[1] = res.s;
    out[2] = res.v;
}

export fn rgb2xyz(red: u8, green: u8, blue: u8, out: [*]f64) void {
    const res = convertColor(Xyz, Rgb{ .r = red, .g = green, .b = blue });
    std.log.debug("XYZ: {[x]d} {[y]d} {[z]d}", res);
    out[0] = res.x;
    out[1] = res.y;
    out[2] = res.z;
}

export fn rgb2lab(red: u8, green: u8, blue: u8, out: [*]f64) void {
    const res = convertColor(Lab, Rgb{ .r = red, .g = green, .b = blue });
    std.log.debug("Lab: {[l]d} {[a]d} {[b]d}", res);
    out[0] = res.l;
    out[1] = res.a;
    out[2] = res.b;
}

export fn rgb2lms(red: u8, green: u8, blue: u8, out: [*]f64) void {
    const res = convertColor(Lms, Rgb{ .r = red, .g = green, .b = blue });
    std.log.debug("LMS: {[l]d} {[m]d} {[s]d}", res);
    out[0] = res.l;
    out[1] = res.m;
    out[2] = res.s;
}

export fn rgb2oklab(red: u8, green: u8, blue: u8, out: [*]f64) void {
    const res = convertColor(Oklab, Rgb{ .r = red, .g = green, .b = blue });
    std.log.debug("Oklab: {[l]d} {[a]d} {[b]d}", res);
    out[0] = res.l;
    out[1] = res.a;
    out[2] = res.b;
}

export fn rgb2oklch(red: u8, green: u8, blue: u8, out: [*]f64) void {
    const res = convertColor(Oklch, Rgb{ .r = red, .g = green, .b = blue });
    std.log.debug("Oklch: {[l]d} {[c]d} {[h]d}", res);
    out[0] = res.l;
    out[1] = res.c;
    out[2] = res.h;
}

export fn rgb2xyb(red: u8, green: u8, blue: u8, out: [*]f64) void {
    const res = convertColor(Xyb, Rgb{ .r = red, .g = green, .b = blue });
    std.log.debug("Xyb: {[x]d} {[y]d} {[b]d}", res);
    out[0] = res.x;
    out[1] = res.y;
    out[2] = res.b;
}

export fn rgb2ycbcr(red: u8, green: u8, blue: u8, out: [*]f64) void {
    const res = convertColor(Ycbcr, Rgb{ .r = red, .g = green, .b = blue });
    std.log.debug("Ycbcr: {[y]d} {[cb]d} {[cr]d}", res);
    out[0] = res.y;
    out[1] = res.cb;
    out[2] = res.cr;
}
// --- HSL ---

export fn hsl2rgb(h: f64, s: f64, l: f64, out: [*]u8) void {
    const res = convertColor(Rgb, Hsl{ .h = h, .s = s, .l = l });
    std.log.debug("RGB: {[r]d} {[g]d} {[b]d}", res);
    out[0] = res.r;
    out[1] = res.g;
    out[2] = res.b;
}

export fn hsl2hsv(h: f64, s: f64, l: f64, out: [*]f64) void {
    const res = convertColor(Hsv, Hsl{ .h = h, .s = s, .l = l });
    std.log.debug("HSV: {[h]d} {[s]d} {[v]d}", res);
    out[0] = res.h;
    out[1] = res.s;
    out[2] = res.v;
}

export fn hsl2xyz(h: f64, s: f64, l: f64, out: [*]f64) void {
    const res = convertColor(Xyz, Hsl{ .h = h, .s = s, .l = l });
    std.log.debug("XYZ: {[x]d} {[y]d} {[z]d}", res);
    out[0] = res.x;
    out[1] = res.y;
    out[2] = res.z;
}

export fn hsl2lab(h: f64, s: f64, l: f64, out: [*]f64) void {
    const res = convertColor(Lab, Hsl{ .h = h, .s = s, .l = l });
    std.log.debug("LAB: {[l]d} {[a]d} {[b]d}", res);
    out[0] = res.l;
    out[1] = res.a;
    out[2] = res.b;
}

export fn hsl2lms(h: f64, s: f64, l: f64, out: [*]f64) void {
    const res = convertColor(Lms, Hsl{ .h = h, .s = s, .l = l });
    std.log.debug("LMS: {[l]d} {[m]d} {[s]d}", res);
    out[0] = res.l;
    out[1] = res.m;
    out[2] = res.s;
}

export fn hsl2oklab(h: f64, s: f64, l: f64, out: [*]f64) void {
    const res = convertColor(Oklab, Hsl{ .h = h, .s = s, .l = l });
    std.log.debug("Oklab: {[l]d} {[a]d} {[b]d}", res);
    out[0] = res.l;
    out[1] = res.a;
    out[2] = res.b;
}

export fn hsl2oklch(h: f64, s: f64, l: f64, out: [*]f64) void {
    const res = convertColor(Oklch, Hsl{ .h = h, .s = s, .l = l });
    std.log.debug("Oklch: {[l]d} {[c]d} {[h]d}", res);
    out[0] = res.l;
    out[1] = res.c;
    out[2] = res.h;
}

export fn hsl2xyb(h: f64, s: f64, l: f64, out: [*]f64) void {
    const res = convertColor(Xyb, Hsl{ .h = h, .s = s, .l = l });
    std.log.debug("Xyb: {[x]d} {[y]d} {[b]d}", res);
    out[0] = res.x;
    out[1] = res.y;
    out[2] = res.b;
}

export fn hsl2ycbcr(h: f64, s: f64, l: f64, out: [*]f64) void {
    const res = convertColor(Ycbcr, Hsl{ .h = h, .s = s, .l = l });
    std.log.debug("Ycbcr: {[y]d} {[cb]d} {[cr]d}", res);
    out[0] = res.y;
    out[1] = res.cb;
    out[2] = res.cr;
}

// --- HSV ---

export fn hsv2rgb(h: f64, s: f64, v: f64, out: [*]u8) void {
    const res = convertColor(Rgb, Hsv{ .h = h, .s = s, .v = v });
    std.log.debug("RGB: {[r]d} {[g]d} {[b]d}", res);
    out[0] = res.r;
    out[1] = res.g;
    out[2] = res.b;
}

export fn hsv2hsl(h: f64, s: f64, v: f64, out: [*]f64) void {
    const res = convertColor(Hsl, Hsv{ .h = h, .s = s, .v = v });
    std.log.debug("HSL: {[h]d} {[s]d} {[l]d}", res);
    out[0] = res.h;
    out[1] = res.s;
    out[2] = res.l;
}

export fn hsv2xyz(h: f64, s: f64, v: f64, out: [*]f64) void {
    const res = convertColor(Xyz, Hsv{ .h = h, .s = s, .v = v });
    std.log.debug("XYZ: {[x]d} {[y]d} {[z]d}", res);
    out[0] = res.x;
    out[1] = res.y;
    out[2] = res.z;
}

export fn hsv2lab(h: f64, s: f64, v: f64, out: [*]f64) void {
    const res = convertColor(Lab, Hsv{ .h = h, .s = s, .v = v });
    std.log.debug("LAB: {[l]d} {[a]d} {[b]d}", res);
    out[0] = res.l;
    out[1] = res.a;
    out[2] = res.b;
}

export fn hsv2lms(h: f64, s: f64, v: f64, out: [*]f64) void {
    const res = convertColor(Lms, Hsv{ .h = h, .s = s, .v = v });
    std.log.debug("LMS: {[l]d} {[m]d} {[s]d}", res);
    out[0] = res.l;
    out[1] = res.m;
    out[2] = res.s;
}

export fn hsv2oklab(h: f64, s: f64, v: f64, out: [*]f64) void {
    const res = convertColor(Oklab, Hsv{ .h = h, .s = s, .v = v });
    std.log.debug("Oklab: {[l]d} {[a]d} {[b]d}", res);
    out[0] = res.l;
    out[1] = res.a;
    out[2] = res.b;
}

export fn hsv2oklch(h: f64, s: f64, v: f64, out: [*]f64) void {
    const res = convertColor(Oklch, Hsv{ .h = h, .s = s, .v = v });
    std.log.debug("Oklch: {[l]d} {[c]d} {[h]d}", res);
    out[0] = res.l;
    out[1] = res.c;
    out[2] = res.h;
}

export fn hsv2xyb(h: f64, s: f64, v: f64, out: [*]f64) void {
    const res = convertColor(Xyb, Hsv{ .h = h, .s = s, .v = v });
    std.log.debug("Xyb: {[x]d} {[y]d} {[b]d}", res);
    out[0] = res.x;
    out[1] = res.y;
    out[2] = res.b;
}

export fn hsv2ycbcr(h: f64, s: f64, v: f64, out: [*]f64) void {
    const res = convertColor(Ycbcr, Hsv{ .h = h, .s = s, .v = v });
    std.log.debug("Ycbcr: {[y]d} {[cb]d} {[cr]d}", res);
    out[0] = res.y;
    out[1] = res.cb;
    out[2] = res.cr;
}

// --- XYZ ---

export fn xyz2rgb(x: f64, y: f64, z: f64, out: [*]u8) void {
    const res = convertColor(Rgb, Xyz{ .x = x, .y = y, .z = z });
    std.log.debug("RGB: {[r]d} {[g]d} {[b]d}", res);
    out[0] = res.r;
    out[1] = res.g;
    out[2] = res.b;
}

export fn xyz2hsl(x: f64, y: f64, z: f64, out: [*]f64) void {
    const res = convertColor(Hsl, Xyz{ .x = x, .y = y, .z = z });
    std.log.debug("HSL: {[h]d} {[s]d} {[l]d}", res);
    out[0] = res.h;
    out[1] = res.s;
    out[2] = res.l;
}

export fn xyz2hsv(x: f64, y: f64, z: f64, out: [*]f64) void {
    const res = convertColor(Hsv, Xyz{ .x = x, .y = y, .z = z });
    std.log.debug("HSV: {[h]d} {[s]d} {[v]d}", res);
    out[0] = res.h;
    out[1] = res.s;
    out[2] = res.v;
}

export fn xyz2lab(x: f64, y: f64, z: f64, out: [*]f64) void {
    const res = convertColor(Lab, Xyz{ .x = x, .y = y, .z = z });
    std.log.debug("LAB: {[l]d} {[a]d} {[b]d}", res);
    out[0] = res.l;
    out[1] = res.a;
    out[2] = res.b;
}

export fn xyz2lms(l: f64, m: f64, s: f64, out: [*]f64) void {
    const res = convertColor(Lms, Xyz{ .x = l, .y = m, .z = s });
    std.log.debug("LMS: {[l]d} {[m]d} {[s]d}", res);
    out[0] = res.l;
    out[1] = res.m;
    out[2] = res.s;
}

export fn xyz2oklab(x: f64, y: f64, z: f64, out: [*]f64) void {
    const res = convertColor(Oklab, Xyz{ .x = x, .y = y, .z = z });
    std.log.debug("Oklab: {[l]d} {[a]d} {[b]d}", res);
    out[0] = res.l;
    out[1] = res.a;
    out[2] = res.b;
}

export fn xyz2oklch(x: f64, y: f64, z: f64, out: [*]f64) void {
    const res = convertColor(Oklch, Xyz{ .x = x, .y = y, .z = z });
    std.log.debug("Oklch: {[l]d} {[c]d} {[h]d}", res);
    out[0] = res.l;
    out[1] = res.c;
    out[2] = res.h;
}

export fn xyz2xyb(x: f64, y: f64, z: f64, out: [*]f64) void {
    const res = convertColor(Xyb, Xyz{ .x = x, .y = y, .z = z });
    std.log.debug("Xyb: {[x]d} {[y]d} {[b]d}", res);
    out[0] = res.x;
    out[1] = res.y;
    out[2] = res.b;
}

export fn xyz2ycbcr(x: f64, y: f64, z: f64, out: [*]f64) void {
    const res = convertColor(Ycbcr, Xyz{ .x = x, .y = y, .z = z });
    std.log.debug("Ycbcr: {[y]d} {[cb]d} {[cr]d}", res);
    out[0] = res.y;
    out[1] = res.cb;
    out[2] = res.cr;
}

// --- LAB ---

export fn lab2rgb(l: f64, a: f64, b: f64, out: [*]u8) void {
    const res = convertColor(Rgb, Lab{ .l = l, .a = a, .b = b });
    std.log.debug("RGB: {[r]d} {[g]d} {[b]d}", res);
    out[0] = res.r;
    out[1] = res.g;
    out[2] = res.b;
}

export fn lab2hsl(l: f64, a: f64, b: f64, out: [*]f64) void {
    const res = convertColor(Hsl, Lab{ .l = l, .a = a, .b = b });
    std.log.debug("HSL: {[h]d} {[s]d} {[l]d}", res);
    out[0] = res.h;
    out[1] = res.s;
    out[2] = res.l;
}

export fn lab2hsv(l: f64, a: f64, b: f64, out: [*]f64) void {
    const res = convertColor(Hsv, Lab{ .l = l, .a = a, .b = b });
    std.log.debug("HSV: {[h]d} {[s]d} {[v]d}", res);
    out[0] = res.h;
    out[1] = res.s;
    out[2] = res.v;
}

export fn lab2xyz(l: f64, a: f64, b: f64, out: [*]f64) void {
    const res = convertColor(Xyz, Lab{ .l = l, .a = a, .b = b });
    std.log.debug("XYZ: {[x]d} {[y]d} {[z]d}", res);
    out[0] = res.x;
    out[1] = res.y;
    out[2] = res.z;
}

export fn lab2lms(l: f64, a: f64, b: f64, out: [*]f64) void {
    const res = convertColor(Lms, Lab{ .l = l, .a = a, .b = b });
    std.log.debug("LMS: {[l]d} {[m]d} {[s]d}", res);
    out[0] = res.l;
    out[1] = res.m;
    out[2] = res.s;
}

export fn lab2oklab(l: f64, a: f64, b: f64, out: [*]f64) void {
    const res = convertColor(Oklab, Lab{ .l = l, .a = a, .b = b });
    std.log.debug("Oklab: {[l]d} {[a]d} {[b]d}", res);
    out[0] = res.l;
    out[1] = res.a;
    out[2] = res.b;
}

export fn lab2oklch(l: f64, a: f64, b: f64, out: [*]f64) void {
    const res = convertColor(Oklch, Lab{ .l = l, .a = a, .b = b });
    std.log.debug("Oklch: {[l]d} {[c]d} {[h]d}", res);
    out[0] = res.l;
    out[1] = res.c;
    out[2] = res.h;
}

export fn lab2xyb(l: f64, a: f64, b: f64, out: [*]f64) void {
    const res = convertColor(Xyb, Lab{ .l = l, .a = a, .b = b });
    std.log.debug("Xyb: {[x]d} {[y]d} {[b]d}", res);
    out[0] = res.x;
    out[1] = res.y;
    out[2] = res.b;
}

// --- LMS ---

export fn lms2rgb(l: f64, m: f64, s: f64, out: [*]u8) void {
    const res = convertColor(Rgb, Lms{ .l = l, .m = m, .s = s });
    std.log.debug("RGB: {[r]d} {[g]d} {[b]d}", res);
    out[0] = res.r;
    out[1] = res.g;
    out[2] = res.b;
}

export fn lms2hsl(l: f64, m: f64, s: f64, out: [*]f64) void {
    const res = convertColor(Hsl, Lms{ .l = l, .m = m, .s = s });
    std.log.debug("HSL: {[h]d} {[s]d} {[l]d}", res);
    out[0] = res.h;
    out[1] = res.s;
    out[2] = res.l;
}

export fn lms2hsv(l: f64, m: f64, s: f64, out: [*]f64) void {
    const res = convertColor(Hsv, Lms{ .l = l, .m = m, .s = s });
    std.log.debug("HSV: {[h]d} {[s]d} {[v]d}", res);
    out[0] = res.h;
    out[1] = res.s;
    out[2] = res.v;
}

export fn lms2xyz(l: f64, m: f64, s: f64, out: [*]f64) void {
    const res = convertColor(Xyz, Lms{ .l = l, .m = m, .s = s });
    std.log.debug("XYZ: {[x]d} {[y]d} {[z]d}", res);
    out[0] = res.x;
    out[1] = res.y;
    out[2] = res.z;
}

export fn lms2lab(l: f64, m: f64, s: f64, out: [*]f64) void {
    const res = convertColor(Lms, Lms{ .l = l, .m = m, .s = s });
    std.log.debug("LMS: {[l]d} {[m]d} {[s]d}", res);
    out[0] = res.l;
    out[1] = res.m;
    out[2] = res.s;
}

export fn lms2oklab(h: f64, m: f64, s: f64, out: [*]f64) void {
    const res = convertColor(Oklab, Lms{ .l = h, .m = m, .s = s });
    std.log.debug("Oklab: {[l]d} {[a]d} {[b]d}", res);
    out[0] = res.l;
    out[1] = res.a;
    out[2] = res.b;
}

export fn lms2oklch(l: f64, m: f64, s: f64, out: [*]f64) void {
    const res = convertColor(Oklch, Lms{ .l = l, .m = m, .s = s });
    std.log.debug("Oklch: {[l]d} {[c]d} {[h]d}", res);
    out[0] = res.l;
    out[1] = res.c;
    out[2] = res.h;
}

export fn lms2xyb(l: f64, m: f64, s: f64, out: [*]f64) void {
    const res = convertColor(Xyb, Lms{ .l = l, .m = m, .s = s });
    std.log.debug("Xyb: {[x]d} {[y]d} {[b]d}", res);
    out[0] = res.x;
    out[1] = res.y;
    out[2] = res.b;
}

// --- Oklab ---

export fn oklab2rgb(l: f64, a: f64, b: f64, out: [*]u8) void {
    const res = convertColor(Rgb, Oklab{ .l = l, .a = a, .b = b });
    std.log.debug("RGB: {[r]d} {[g]d} {[b]d}", res);
    out[0] = res.r;
    out[1] = res.g;
    out[2] = res.b;
}

export fn oklab2hsl(l: f64, a: f64, b: f64, out: [*]f64) void {
    const res = convertColor(Hsl, Oklab{ .l = l, .a = a, .b = b });
    std.log.debug("HSL: {[h]d} {[s]d} {[l]d}", res);
    out[0] = res.h;
    out[1] = res.s;
    out[2] = res.l;
}

export fn oklab2hsv(l: f64, a: f64, b: f64, out: [*]f64) void {
    const res = convertColor(Hsv, Oklab{ .l = l, .a = a, .b = b });
    std.log.debug("HSV: {[h]d} {[s]d} {[v]d}", res);
    out[0] = res.h;
    out[1] = res.s;
    out[2] = res.v;
}

export fn oklab2xyz(l: f64, a: f64, b: f64, out: [*]f64) void {
    const res = convertColor(Xyz, Oklab{ .l = l, .a = a, .b = b });
    std.log.debug("XYZ: {[x]d} {[y]d} {[z]d}", res);
    out[0] = res.x;
    out[1] = res.y;
    out[2] = res.z;
}

export fn oklab2lms(l: f64, a: f64, b: f64, out: [*]f64) void {
    const res = convertColor(Lms, Oklab{ .l = l, .a = a, .b = b });
    std.log.debug("LMS: {[l]d} {[m]d} {[s]d}", res);
    out[0] = res.l;
    out[1] = res.m;
    out[2] = res.s;
}

export fn oklab2lab(l: f64, a: f64, b: f64, out: [*]f64) void {
    const res = convertColor(Lab, Oklab{ .l = l, .a = a, .b = b });
    std.log.debug("Oklab: {[l]d} {[a]d} {[b]d}", res);
    out[0] = res.l;
    out[1] = res.a;
    out[2] = res.b;
}

export fn oklab2xyb(l: f64, a: f64, b: f64, out: [*]f64) void {
    const res = convertColor(Xyb, Oklab{ .l = l, .a = a, .b = b });
    std.log.debug("Xyb: {[x]d} {[y]d} {[b]d}", res);
    out[0] = res.x;
    out[1] = res.y;
    out[2] = res.b;
}

// --- Oklch ---

export fn oklch2rgb(l: f64, c: f64, h: f64, out: [*]u8) void {
    const res = convertColor(Rgb, Oklch{ .l = l, .c = c, .h = h });
    std.log.debug("RGB: {[r]d} {[g]d} {[b]d}", res);
    out[0] = res.r;
    out[1] = res.g;
    out[2] = res.b;
}

export fn oklch2hsl(l: f64, c: f64, h: f64, out: [*]f64) void {
    const res = convertColor(Hsl, Oklch{ .l = l, .c = c, .h = h });
    std.log.debug("HSL: {[h]d} {[s]d} {[l]d}", res);
    out[0] = res.h;
    out[1] = res.s;
    out[2] = res.l;
}

export fn oklch2hsv(l: f64, c: f64, h: f64, out: [*]f64) void {
    const res = convertColor(Hsv, Oklch{ .l = l, .c = c, .h = h });
    std.log.debug("HSV: {[h]d} {[s]d} {[v]d}", res);
    out[0] = res.h;
    out[1] = res.s;
    out[2] = res.v;
}

export fn oklch2xyz(l: f64, c: f64, h: f64, out: [*]f64) void {
    const res = convertColor(Xyz, Oklch{ .l = l, .c = c, .h = h });
    std.log.debug("XYZ: {[x]d} {[y]d} {[z]d}", res);
    out[0] = res.x;
    out[1] = res.y;
    out[2] = res.z;
}

export fn oklch2lab(l: f64, c: f64, h: f64, out: [*]f64) void {
    const res = convertColor(Lab, Oklch{ .l = l, .c = c, .h = h });
    std.log.debug("Lab: {[l]d} {[a]d} {[b]d}", res);
    out[0] = res.l;
    out[1] = res.a;
    out[2] = res.b;
}

export fn oklch2lms(l: f64, c: f64, h: f64, out: [*]f64) void {
    const res = convertColor(Lms, Oklch{ .l = l, .c = c, .h = h });
    std.log.debug("LMS: {[l]d} {[m]d} {[s]d}", res);
    out[0] = res.l;
    out[1] = res.m;
    out[2] = res.s;
}

export fn oklch2oklab(l: f64, c: f64, h: f64, out: [*]f64) void {
    const res = convertColor(Oklab, Oklch{ .l = l, .c = c, .h = h });
    std.log.debug("Oklab: {[l]d} {[a]d} {[b]d}", res);
    out[0] = res.l;
    out[1] = res.a;
    out[2] = res.b;
}

export fn oklch2xyb(l: f64, c: f64, h: f64, out: [*]f64) void {
    const res = convertColor(Xyb, Oklch{ .l = l, .c = c, .h = h });
    std.log.debug("Xyb: {[x]d} {[y]d} {[b]d}", res);
    out[0] = res.x;
    out[1] = res.y;
    out[2] = res.b;
}

export fn oklch2ycbcr(l: f64, c: f64, h: f64, out: [*]f64) void {
    const res = convertColor(Ycbcr, Oklch{ .l = l, .c = c, .h = h });
    std.log.debug("Ycbcr: {[y]d} {[cb]d} {[cr]d}", res);
    out[0] = res.y;
    out[1] = res.cb;
    out[2] = res.cr;
}

// --- XYB ---

export fn xyb2rgb(x: f64, y: f64, b: f64, out: [*]u8) void {
    const res = convertColor(Rgb, Xyb{ .x = x, .y = y, .b = b });
    std.log.debug("RGB: {[r]d} {[g]d} {[b]d}", res);
    out[0] = res.r;
    out[1] = res.g;
    out[2] = res.b;
}

export fn xyb2hsl(x: f64, y: f64, b: f64, out: [*]f64) void {
    const res = convertColor(Hsl, Xyb{ .x = x, .y = y, .b = b });
    std.log.debug("HSL: {[h]d} {[s]d} {[l]d}", res);
    out[0] = res.h;
    out[1] = res.s;
    out[2] = res.l;
}

export fn xyb2hsv(x: f64, y: f64, b: f64, out: [*]f64) void {
    const res = convertColor(Hsv, Xyb{ .x = x, .y = y, .b = b });
    std.log.debug("HSV: {[h]d} {[s]d} {[v]d}", res);
    out[0] = res.h;
    out[1] = res.s;
    out[2] = res.v;
}

export fn xyb2xyz(x: f64, y: f64, b: f64, out: [*]f64) void {
    const res = convertColor(Xyz, Xyb{ .x = x, .y = y, .b = b });
    std.log.debug("XYZ: {[x]d} {[y]d} {[z]d}", res);
    out[0] = res.x;
    out[1] = res.y;
    out[2] = res.z;
}

export fn xyb2lms(x: f64, y: f64, b: f64, out: [*]f64) void {
    const res = convertColor(Lms, Xyb{ .x = x, .y = y, .b = b });
    std.log.debug("LMS: {[l]d} {[m]d} {[s]d}", res);
    out[0] = res.l;
    out[1] = res.m;
    out[2] = res.s;
}

export fn xyb2oklab(x: f64, y: f64, b: f64, out: [*]f64) void {
    const res = convertColor(Oklab, Xyb{ .x = x, .y = y, .b = b });
    std.log.debug("Oklab: {[l]d} {[a]d} {[b]d}", res);
    out[0] = res.l;
    out[1] = res.a;
    out[2] = res.b;
}

export fn xyb2oklch(x: f64, y: f64, b: f64, out: [*]f64) void {
    const res = convertColor(Oklch, Xyb{ .x = x, .y = y, .b = b });
    std.log.debug("Oklch: {[l]d} {[c]d} {[h]d}", res);
    out[0] = res.l;
    out[1] = res.c;
    out[2] = res.h;
}

export fn xyb2lab(x: f64, y: f64, b: f64, out: [*]f64) void {
    const res = convertColor(Lab, Xyb{ .x = x, .y = y, .b = b });
    std.log.debug("Lab: {[l]d} {[a]d} {[b]d}", res);
    out[0] = res.l;
    out[1] = res.a;
    out[2] = res.b;
}

// Add all remaining Ycbcr conversion functions
export fn lab2ycbcr(l: f64, a: f64, b: f64, out: [*]f64) void {
    const res = convertColor(Ycbcr, Lab{ .l = l, .a = a, .b = b });
    std.log.debug("Ycbcr: {[y]d} {[cb]d} {[cr]d}", res);
    out[0] = res.y;
    out[1] = res.cb;
    out[2] = res.cr;
}

export fn lms2ycbcr(l: f64, m: f64, s: f64, out: [*]f64) void {
    const res = convertColor(Ycbcr, Lms{ .l = l, .m = m, .s = s });
    std.log.debug("Ycbcr: {[y]d} {[cb]d} {[cr]d}", res);
    out[0] = res.y;
    out[1] = res.cb;
    out[2] = res.cr;
}

export fn oklab2ycbcr(l: f64, a: f64, b: f64, out: [*]f64) void {
    const res = convertColor(Ycbcr, Oklab{ .l = l, .a = a, .b = b });
    std.log.debug("Ycbcr: {[y]d} {[cb]d} {[cr]d}", res);
    out[0] = res.y;
    out[1] = res.cb;
    out[2] = res.cr;
}

export fn xyb2ycbcr(x: f64, y: f64, b: f64, out: [*]f64) void {
    const res = convertColor(Ycbcr, Xyb{ .x = x, .y = y, .b = b });
    std.log.debug("Ycbcr: {[y]d} {[cb]d} {[cr]d}", res);
    out[0] = res.y;
    out[1] = res.cb;
    out[2] = res.cr;
}

// --- YCBCR ---

export fn ycbcr2rgb(y: f64, cb: f64, cr: f64, out: [*]u8) void {
    const res = convertColor(Rgb, Ycbcr{ .y = @floatCast(y), .cb = @floatCast(cb), .cr = @floatCast(cr) });
    std.log.debug("RGB: {[r]d} {[g]d} {[b]d}", res);
    out[0] = res.r;
    out[1] = res.g;
    out[2] = res.b;
}

export fn ycbcr2hsl(y: f64, cb: f64, cr: f64, out: [*]f64) void {
    const res = convertColor(Hsl, Ycbcr{ .y = @floatCast(y), .cb = @floatCast(cb), .cr = @floatCast(cr) });
    std.log.debug("HSL: {[h]d} {[s]d} {[l]d}", res);
    out[0] = res.h;
    out[1] = res.s;
    out[2] = res.l;
}

export fn ycbcr2hsv(y: f64, cb: f64, cr: f64, out: [*]f64) void {
    const res = convertColor(Hsv, Ycbcr{ .y = @floatCast(y), .cb = @floatCast(cb), .cr = @floatCast(cr) });
    std.log.debug("HSV: {[h]d} {[s]d} {[v]d}", res);
    out[0] = res.h;
    out[1] = res.s;
    out[2] = res.v;
}

export fn ycbcr2xyz(y: f64, cb: f64, cr: f64, out: [*]f64) void {
    const res = convertColor(Xyz, Ycbcr{ .y = @floatCast(y), .cb = @floatCast(cb), .cr = @floatCast(cr) });
    std.log.debug("XYZ: {[x]d} {[y]d} {[z]d}", res);
    out[0] = res.x;
    out[1] = res.y;
    out[2] = res.z;
}

export fn ycbcr2lab(y: f64, cb: f64, cr: f64, out: [*]f64) void {
    const res = convertColor(Lab, Ycbcr{ .y = @floatCast(y), .cb = @floatCast(cb), .cr = @floatCast(cr) });
    std.log.debug("Lab: {[l]d} {[a]d} {[b]d}", res);
    out[0] = res.l;
    out[1] = res.a;
    out[2] = res.b;
}

export fn ycbcr2lms(y: f64, cb: f64, cr: f64, out: [*]f64) void {
    const res = convertColor(Lms, Ycbcr{ .y = @floatCast(y), .cb = @floatCast(cb), .cr = @floatCast(cr) });
    std.log.debug("LMS: {[l]d} {[m]d} {[s]d}", res);
    out[0] = res.l;
    out[1] = res.m;
    out[2] = res.s;
}

export fn ycbcr2oklab(y: f64, cb: f64, cr: f64, out: [*]f64) void {
    const res = convertColor(Oklab, Ycbcr{ .y = @floatCast(y), .cb = @floatCast(cb), .cr = @floatCast(cr) });
    std.log.debug("Oklab: {[l]d} {[a]d} {[b]d}", res);
    out[0] = res.l;
    out[1] = res.a;
    out[2] = res.b;
}

export fn ycbcr2oklch(y: f64, cb: f64, cr: f64, out: [*]f64) void {
    const res = convertColor(Oklch, Ycbcr{ .y = @floatCast(y), .cb = @floatCast(cb), .cr = @floatCast(cr) });
    std.log.debug("Oklch: {[l]d} {[c]d} {[h]d}", res);
    out[0] = res.l;
    out[1] = res.c;
    out[2] = res.h;
}

export fn ycbcr2xyb(y: f64, cb: f64, cr: f64, out: [*]f64) void {
    const res = convertColor(Xyb, Ycbcr{ .y = @floatCast(y), .cb = @floatCast(cb), .cr = @floatCast(cr) });
    std.log.debug("Xyb: {[x]d} {[y]d} {[b]d}", res);
    out[0] = res.x;
    out[1] = res.y;
    out[2] = res.b;
}

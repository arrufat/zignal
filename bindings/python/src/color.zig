//! Color bindings using the automated registry-based approach

const std = @import("std");
const zignal = @import("zignal");

// Explicit imports for types used in public exports
const Gray = zignal.Gray(u8);
const Rgb = zignal.Rgb(u8);
const Rgba = zignal.Rgba(u8);
const Hsl = zignal.Hsl(f64);
const Hsv = zignal.Hsv(f64);
const Lab = zignal.Lab(f64);
const Lch = zignal.Lch(f64);
const Lms = zignal.Lms(f64);
const Oklab = zignal.Oklab(f64);
const Oklch = zignal.Oklch(f64);
const Xyb = zignal.Xyb(f64);
const Xyz = zignal.Xyz(f64);
const Ycbcr = zignal.Ycbcr(u8);

const color_factory = @import("color_factory.zig");
const color_registry = @import("color_registry.zig");
const py_utils = @import("py_utils.zig");
pub const registerType = py_utils.registerType;
const c = py_utils.c;

// ============================================================================
// GENERIC COLOR TYPE GENERATION
// ============================================================================

/// Helper to extract clean name like "Rgb" from "zignal.Rgb"
fn getTypeName(comptime ColorType: type) []const u8 {
    const full_name = @typeName(ColorType);
    var i = full_name.len;
    while (i > 0) : (i -= 1) {
        if (full_name[i - 1] == '.') break;
    }
    const sliced = full_name[i..];
    if (std.mem.findScalar(u8, sliced, '(')) |paren| {
        return sliced[0..paren];
    }
    return sliced;
}

/// Generic state container for a color type
/// This holds the static data (methods, getsets) required for the Python type object.
/// We use this to keep the backing arrays alive and stable in memory.
fn ColorState(comptime ColorType: type) type {
    const Binding = color_factory.ColorBinding(ColorType);
    return struct {
        // Generate static arrays for this specific color type
        // These are variables in a generic struct, so they are static (one instance per ColorType)
        var getset = Binding.generateGetSet();
        var methods = Binding.generateMethods();

        // Helper to produce the TypeObject initialized with pointers to the above arrays
        fn createTypeObject() c.PyTypeObject {
            return generateColorTypeObject(ColorType, Binding, @ptrCast(&getset), @ptrCast(&methods));
        }
    };
}

/// Generate PyTypeObject for a specific color type
fn generateColorTypeObject(comptime ColorType: type, comptime Binding: type, getset_ptr: [*]c.PyGetSetDef, methods_ptr: [*]c.PyMethodDef) c.PyTypeObject {
    const type_name = getTypeName(ColorType);
    const module_name = comptime "zignal." ++ type_name;

    return c.PyTypeObject{
        .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
        .tp_name = module_name,
        .tp_basicsize = @sizeOf(Binding.PyObjectType),
        .tp_dealloc = @ptrCast(&Binding.dealloc),
        .tp_repr = @ptrCast(&Binding.repr),
        .tp_str = @ptrCast(&Binding.repr),
        .tp_flags = c.Py_TPFLAGS_DEFAULT,
        .tp_doc = color_registry.getDocumentationString(ColorType).ptr,
        .tp_methods = methods_ptr,
        .tp_getset = getset_ptr,
        .tp_init = @ptrCast(&Binding.init),
        .tp_new = @ptrCast(&Binding.new),
        .tp_richcompare = @ptrCast(&Binding.richcompare),
    };
}

// ============================================================================
// PUBLIC EXPORTS (Required by other modules)
// ============================================================================

// We explicity export the TypeObjects and Bindings for each color type.
// Other modules (like pixel_proxy.zig) rely on these names (e.g. RgbType).

pub const GrayBinding = color_factory.ColorBinding(Gray);
pub var gray = ColorState(Gray).createTypeObject();

pub const RgbBinding = color_factory.ColorBinding(Rgb);
pub var rgb = ColorState(Rgb).createTypeObject();

pub const RgbaBinding = color_factory.ColorBinding(Rgba);
pub var rgba = ColorState(Rgba).createTypeObject();

pub const HslBinding = color_factory.ColorBinding(Hsl);
pub var hsl = ColorState(Hsl).createTypeObject();

pub const HsvBinding = color_factory.ColorBinding(Hsv);
pub var hsv = ColorState(Hsv).createTypeObject();

pub const LabBinding = color_factory.ColorBinding(Lab);
pub var lab = ColorState(Lab).createTypeObject();

pub const LchBinding = color_factory.ColorBinding(Lch);
pub var lch = ColorState(Lch).createTypeObject();

pub const LmsBinding = color_factory.ColorBinding(Lms);
pub var lms = ColorState(Lms).createTypeObject();

pub const OklabBinding = color_factory.ColorBinding(Oklab);
pub var oklab = ColorState(Oklab).createTypeObject();

pub const OklchBinding = color_factory.ColorBinding(Oklch);
pub var oklch = ColorState(Oklch).createTypeObject();

pub const XybBinding = color_factory.ColorBinding(Xyb);
pub var xyb = ColorState(Xyb).createTypeObject();

pub const XyzBinding = color_factory.ColorBinding(Xyz);
pub var xyz = ColorState(Xyz).createTypeObject();

pub const YcbcrBinding = color_factory.ColorBinding(Ycbcr);
pub var ycbcr = ColorState(Ycbcr).createTypeObject();

// ============================================================================
// REGISTRATION HELPER
// ============================================================================

/// Register all color types from the registry in one go
pub fn registerAllColorTypes(module: [*c]c.PyObject) !void {
    try registerType(@ptrCast(module), "Gray", @ptrCast(&gray));
    try registerType(@ptrCast(module), "Rgb", @ptrCast(&rgb));
    try registerType(@ptrCast(module), "Rgba", @ptrCast(&rgba));
    try registerType(@ptrCast(module), "Hsl", @ptrCast(&hsl));
    try registerType(@ptrCast(module), "Hsv", @ptrCast(&hsv));
    try registerType(@ptrCast(module), "Lab", @ptrCast(&lab));
    try registerType(@ptrCast(module), "Lch", @ptrCast(&lch));
    try registerType(@ptrCast(module), "Lms", @ptrCast(&lms));
    try registerType(@ptrCast(module), "Oklab", @ptrCast(&oklab));
    try registerType(@ptrCast(module), "Oklch", @ptrCast(&oklch));
    try registerType(@ptrCast(module), "Xyb", @ptrCast(&xyb));
    try registerType(@ptrCast(module), "Xyz", @ptrCast(&xyz));
    try registerType(@ptrCast(module), "Ycbcr", @ptrCast(&ycbcr));
}

// ============================================================================
// CONVERSION HELPERS BETWEEN COLOR TYPES
// ============================================================================

pub fn createColorPyObject(color: anytype) ?*c.PyObject {
    const ColorType = @TypeOf(color);

    return switch (ColorType) {
        Gray => GrayBinding.createPyObject(color, &gray),
        Rgb => RgbBinding.createPyObject(color, &rgb),
        Rgba => RgbaBinding.createPyObject(color, &rgba),
        Hsl => HslBinding.createPyObject(color, &hsl),
        Hsv => HsvBinding.createPyObject(color, &hsv),
        Lab => LabBinding.createPyObject(color, &lab),
        Lch => LchBinding.createPyObject(color, &lch),
        Lms => LmsBinding.createPyObject(color, &lms),
        Oklab => OklabBinding.createPyObject(color, &oklab),
        Oklch => OklchBinding.createPyObject(color, &oklch),
        Xyb => XybBinding.createPyObject(color, &xyb),
        Xyz => XyzBinding.createPyObject(color, &xyz),
        Ycbcr => YcbcrBinding.createPyObject(color, &ycbcr),
        else => null,
    };
}

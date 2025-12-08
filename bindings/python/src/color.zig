//! Color bindings using the automated registry-based approach

const std = @import("std");
const zignal = @import("zignal");

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

// For each color type in the registry, we generate:
// 1. The binding type (e.g., RgbBinding)
// 2. The getset and methods arrays
// 3. The PyTypeObject (e.g., RgbType)

// ============================================================================
// COMPTIME COLOR TYPE GENERATION
// ============================================================================

/// Generate binding struct for a color type
fn ColorBindingFor(comptime ColorType: type) type {
    return color_factory.ColorBinding(ColorType);
}

/// Color type information struct for storing generated data
fn ColorTypeInfo(comptime ColorType: type) type {
    const Binding = ColorBindingFor(ColorType);
    return struct {
        binding: type,
        getset: [@typeInfo(@TypeOf(Binding.generateGetSet())).array.len]c.PyGetSetDef,
        methods: [@typeInfo(@TypeOf(Binding.generateMethods())).array.len]c.PyMethodDef,
        type_object: c.PyTypeObject,
    };
}

/// Generate all color type bindings at comptime
const color_bindings = blk: {
    const num_types = color_registry.color_types.len;
    var bindings: [num_types]type = undefined;

    for (color_registry.color_types, 0..) |ColorType, i| {
        bindings[i] = ColorBindingFor(ColorType);
    }

    break :blk bindings;
};

/// Generate PyTypeObject for a specific color type
fn generateColorTypeObject(comptime ColorType: type, comptime Binding: type, getset_ptr: [*]c.PyGetSetDef, methods_ptr: [*]c.PyMethodDef) c.PyTypeObject {
    const type_name = comptime blk: {
        const full_name = @typeName(ColorType);
        // Extract just the type name (e.g., "Rgb" from "zignal.Rgb")
        var i = full_name.len;
        while (i > 0) : (i -= 1) {
            if (full_name[i - 1] == '.') break;
        }
        const sliced = full_name[i..];
        if (std.mem.indexOfScalar(u8, sliced, '(')) |paren| {
            break :blk sliced[0..paren];
        }
        break :blk sliced;
    };

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

// Generate individual bindings (exported for external use)
pub const GrayBinding = color_bindings[0];
pub const RgbBinding = color_bindings[1];
pub const RgbaBinding = color_bindings[2];
pub const HslBinding = color_bindings[3];
pub const HsvBinding = color_bindings[4];
pub const LabBinding = color_bindings[5];
pub const LchBinding = color_bindings[6];
pub const LmsBinding = color_bindings[7];
pub const OklabBinding = color_bindings[8];
pub const OklchBinding = color_bindings[9];
pub const XybBinding = color_bindings[10];
pub const XyzBinding = color_bindings[11];
pub const YcbcrBinding = color_bindings[12];

// Generate getset arrays
var gray_getset = GrayBinding.generateGetSet();
var rgb_getset = RgbBinding.generateGetSet();
var rgba_getset = RgbaBinding.generateGetSet();
var hsl_getset = HslBinding.generateGetSet();
var hsv_getset = HsvBinding.generateGetSet();
var lab_getset = LabBinding.generateGetSet();
var lch_getset = LchBinding.generateGetSet();
var lms_getset = LmsBinding.generateGetSet();
var oklab_getset = OklabBinding.generateGetSet();
var oklch_getset = OklchBinding.generateGetSet();
var xyb_getset = XybBinding.generateGetSet();
var xyz_getset = XyzBinding.generateGetSet();
var ycbcr_getset = YcbcrBinding.generateGetSet();

// Generate methods arrays
var gray_methods = GrayBinding.generateMethods();
var rgb_methods = RgbBinding.generateMethods();
var rgba_methods = RgbaBinding.generateMethods();
var hsl_methods = HslBinding.generateMethods();
var hsv_methods = HsvBinding.generateMethods();
var lab_methods = LabBinding.generateMethods();
var lch_methods = LchBinding.generateMethods();
var lms_methods = LmsBinding.generateMethods();
var oklab_methods = OklabBinding.generateMethods();
var oklch_methods = OklchBinding.generateMethods();
var xyb_methods = XybBinding.generateMethods();
var xyz_methods = XyzBinding.generateMethods();
var ycbcr_methods = YcbcrBinding.generateMethods();

// Generate type objects
pub var GrayType = generateColorTypeObject(Gray, GrayBinding, @ptrCast(&gray_getset), @ptrCast(&gray_methods));
pub var RgbType = generateColorTypeObject(Rgb, RgbBinding, @ptrCast(&rgb_getset), @ptrCast(&rgb_methods));
pub var RgbaType = generateColorTypeObject(Rgba, RgbaBinding, @ptrCast(&rgba_getset), @ptrCast(&rgba_methods));
pub var HslType = generateColorTypeObject(Hsl, HslBinding, @ptrCast(&hsl_getset), @ptrCast(&hsl_methods));
pub var HsvType = generateColorTypeObject(Hsv, HsvBinding, @ptrCast(&hsv_getset), @ptrCast(&hsv_methods));
pub var LabType = generateColorTypeObject(Lab, LabBinding, @ptrCast(&lab_getset), @ptrCast(&lab_methods));
pub var LchType = generateColorTypeObject(Lch, LchBinding, @ptrCast(&lch_getset), @ptrCast(&lch_methods));
pub var LmsType = generateColorTypeObject(Lms, LmsBinding, @ptrCast(&lms_getset), @ptrCast(&lms_methods));
pub var OklabType = generateColorTypeObject(Oklab, OklabBinding, @ptrCast(&oklab_getset), @ptrCast(&oklab_methods));
pub var OklchType = generateColorTypeObject(Oklch, OklchBinding, @ptrCast(&oklch_getset), @ptrCast(&oklch_methods));
pub var XybType = generateColorTypeObject(Xyb, XybBinding, @ptrCast(&xyb_getset), @ptrCast(&xyb_methods));
pub var XyzType = generateColorTypeObject(Xyz, XyzBinding, @ptrCast(&xyz_getset), @ptrCast(&xyz_methods));
pub var YcbcrType = generateColorTypeObject(Ycbcr, YcbcrBinding, @ptrCast(&ycbcr_getset), @ptrCast(&ycbcr_methods));

// ============================================================================
// REGISTRATION HELPER
// ============================================================================

/// Register all color types from the registry in one go
pub fn registerAllColorTypes(module: [*c]c.PyObject) !void {
    // Register each type - order matches color_registry.color_types
    try registerType(@ptrCast(module), "Gray", @ptrCast(&GrayType));
    try registerType(@ptrCast(module), "Rgb", @ptrCast(&RgbType));
    try registerType(@ptrCast(module), "Rgba", @ptrCast(&RgbaType));
    try registerType(@ptrCast(module), "Hsl", @ptrCast(&HslType));
    try registerType(@ptrCast(module), "Hsv", @ptrCast(&HsvType));
    try registerType(@ptrCast(module), "Lab", @ptrCast(&LabType));
    try registerType(@ptrCast(module), "Lch", @ptrCast(&LchType));
    try registerType(@ptrCast(module), "Lms", @ptrCast(&LmsType));
    try registerType(@ptrCast(module), "Oklab", @ptrCast(&OklabType));
    try registerType(@ptrCast(module), "Oklch", @ptrCast(&OklchType));
    try registerType(@ptrCast(module), "Xyb", @ptrCast(&XybType));
    try registerType(@ptrCast(module), "Xyz", @ptrCast(&XyzType));
    try registerType(@ptrCast(module), "Ycbcr", @ptrCast(&YcbcrType));
}

// ============================================================================
// CONVERSION HELPERS BETWEEN COLOR TYPES
// ============================================================================

/// Create a Python object from any zignal color type
pub fn createColorPyObject(color: anytype) ?*c.PyObject {
    const ColorType = @TypeOf(color);

    return switch (ColorType) {
        Gray => GrayBinding.createPyObject(color, &GrayType),
        Rgb => RgbBinding.createPyObject(color, &RgbType),
        Rgba => RgbaBinding.createPyObject(color, &RgbaType),
        Hsl => HslBinding.createPyObject(color, &HslType),
        Hsv => HsvBinding.createPyObject(color, &HsvType),
        Lab => LabBinding.createPyObject(color, &LabType),
        Lch => LchBinding.createPyObject(color, &LchType),
        Lms => LmsBinding.createPyObject(color, &LmsType),
        Oklab => OklabBinding.createPyObject(color, &OklabType),
        Oklch => OklchBinding.createPyObject(color, &OklchType),
        Xyb => XybBinding.createPyObject(color, &XybType),
        Xyz => XyzBinding.createPyObject(color, &XyzType),
        Ycbcr => YcbcrBinding.createPyObject(color, &YcbcrType),
        else => null,
    };
}

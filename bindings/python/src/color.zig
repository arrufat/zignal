//! Color bindings using the automated registry-based approach

const zignal = @import("zignal");

const color_factory = @import("color_factory.zig");
const color_registry = @import("color_registry.zig");
const py_utils = @import("py_utils.zig");
pub const registerType = py_utils.registerType;
const c = py_utils.c;

// For each color type in the registry, we generate:
// 1. The binding type (e.g., RgbBinding)
// 2. The getset and methods arrays
// 3. The PyTypeObject (e.g., RgbType)

// RGB
pub const RgbBinding = color_factory.createColorBinding(zignal.Rgb);
var rgb_getset = RgbBinding.generateGetSet();
var rgb_methods = RgbBinding.generateMethods();
pub var RgbType = c.PyTypeObject{
    .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
    .tp_name = "zignal.Rgb",
    .tp_basicsize = @sizeOf(RgbBinding.PyObjectType),
    .tp_dealloc = @ptrCast(&RgbBinding.dealloc),
    .tp_repr = @ptrCast(&RgbBinding.repr),
    .tp_str = @ptrCast(&RgbBinding.repr),
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = color_registry.getDocumentationString(zignal.Rgb).ptr,
    .tp_methods = @ptrCast(&rgb_methods),
    .tp_getset = @ptrCast(&rgb_getset),
    .tp_init = @ptrCast(&RgbBinding.init),
    .tp_new = @ptrCast(&RgbBinding.new),
    .tp_richcompare = @ptrCast(&RgbBinding.richcompare),
};

// RGBA
pub const RgbaBinding = color_factory.createColorBinding(zignal.Rgba);
var rgba_getset = RgbaBinding.generateGetSet();
var rgba_methods = RgbaBinding.generateMethods();
pub var RgbaType = c.PyTypeObject{
    .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
    .tp_name = "zignal.Rgba",
    .tp_basicsize = @sizeOf(RgbaBinding.PyObjectType),
    .tp_dealloc = @ptrCast(&RgbaBinding.dealloc),
    .tp_repr = @ptrCast(&RgbaBinding.repr),
    .tp_str = @ptrCast(&RgbaBinding.repr),
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = color_registry.getDocumentationString(zignal.Rgba).ptr,
    .tp_methods = @ptrCast(&rgba_methods),
    .tp_getset = @ptrCast(&rgba_getset),
    .tp_init = @ptrCast(&RgbaBinding.init),
    .tp_new = @ptrCast(&RgbaBinding.new),
    .tp_richcompare = @ptrCast(&RgbaBinding.richcompare),
};

// HSV
pub const HsvBinding = color_factory.createColorBinding(zignal.Hsv);
var hsv_getset = HsvBinding.generateGetSet();
var hsv_methods = HsvBinding.generateMethods();
pub var HsvType = c.PyTypeObject{
    .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
    .tp_name = "zignal.Hsv",
    .tp_basicsize = @sizeOf(HsvBinding.PyObjectType),
    .tp_dealloc = @ptrCast(&HsvBinding.dealloc),
    .tp_repr = @ptrCast(&HsvBinding.repr),
    .tp_str = @ptrCast(&HsvBinding.repr),
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = color_registry.getDocumentationString(zignal.Hsv).ptr,
    .tp_methods = @ptrCast(&hsv_methods),
    .tp_getset = @ptrCast(&hsv_getset),
    .tp_init = @ptrCast(&HsvBinding.init),
    .tp_new = @ptrCast(&HsvBinding.new),
    .tp_richcompare = @ptrCast(&HsvBinding.richcompare),
};

// HSL
pub const HslBinding = color_factory.createColorBinding(zignal.Hsl);
var hsl_getset = HslBinding.generateGetSet();
var hsl_methods = HslBinding.generateMethods();
pub var HslType = c.PyTypeObject{
    .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
    .tp_name = "zignal.Hsl",
    .tp_basicsize = @sizeOf(HslBinding.PyObjectType),
    .tp_dealloc = @ptrCast(&HslBinding.dealloc),
    .tp_repr = @ptrCast(&HslBinding.repr),
    .tp_str = @ptrCast(&HslBinding.repr),
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = color_registry.getDocumentationString(zignal.Hsl).ptr,
    .tp_methods = @ptrCast(&hsl_methods),
    .tp_getset = @ptrCast(&hsl_getset),
    .tp_init = @ptrCast(&HslBinding.init),
    .tp_new = @ptrCast(&HslBinding.new),
    .tp_richcompare = @ptrCast(&HslBinding.richcompare),
};

// LAB
pub const LabBinding = color_factory.createColorBinding(zignal.Lab);
var lab_getset = LabBinding.generateGetSet();
var lab_methods = LabBinding.generateMethods();
pub var LabType = c.PyTypeObject{
    .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
    .tp_name = "zignal.Lab",
    .tp_basicsize = @sizeOf(LabBinding.PyObjectType),
    .tp_dealloc = @ptrCast(&LabBinding.dealloc),
    .tp_repr = @ptrCast(&LabBinding.repr),
    .tp_str = @ptrCast(&LabBinding.repr),
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = color_registry.getDocumentationString(zignal.Lab).ptr,
    .tp_methods = @ptrCast(&lab_methods),
    .tp_getset = @ptrCast(&lab_getset),
    .tp_init = @ptrCast(&LabBinding.init),
    .tp_new = @ptrCast(&LabBinding.new),
    .tp_richcompare = @ptrCast(&LabBinding.richcompare),
};

// XYZ
pub const XyzBinding = color_factory.createColorBinding(zignal.Xyz);
var xyz_getset = XyzBinding.generateGetSet();
var xyz_methods = XyzBinding.generateMethods();
pub var XyzType = c.PyTypeObject{
    .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
    .tp_name = "zignal.Xyz",
    .tp_basicsize = @sizeOf(XyzBinding.PyObjectType),
    .tp_dealloc = @ptrCast(&XyzBinding.dealloc),
    .tp_repr = @ptrCast(&XyzBinding.repr),
    .tp_str = @ptrCast(&XyzBinding.repr),
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = color_registry.getDocumentationString(zignal.Xyz).ptr,
    .tp_methods = @ptrCast(&xyz_methods),
    .tp_getset = @ptrCast(&xyz_getset),
    .tp_init = @ptrCast(&XyzBinding.init),
    .tp_new = @ptrCast(&XyzBinding.new),
    .tp_richcompare = @ptrCast(&XyzBinding.richcompare),
};

// OKLAB
pub const OklabBinding = color_factory.createColorBinding(zignal.Oklab);
var oklab_getset = OklabBinding.generateGetSet();
var oklab_methods = OklabBinding.generateMethods();
pub var OklabType = c.PyTypeObject{
    .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
    .tp_name = "zignal.Oklab",
    .tp_basicsize = @sizeOf(OklabBinding.PyObjectType),
    .tp_dealloc = @ptrCast(&OklabBinding.dealloc),
    .tp_repr = @ptrCast(&OklabBinding.repr),
    .tp_str = @ptrCast(&OklabBinding.repr),
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = color_registry.getDocumentationString(zignal.Oklab).ptr,
    .tp_methods = @ptrCast(&oklab_methods),
    .tp_getset = @ptrCast(&oklab_getset),
    .tp_init = @ptrCast(&OklabBinding.init),
    .tp_new = @ptrCast(&OklabBinding.new),
    .tp_richcompare = @ptrCast(&OklabBinding.richcompare),
};

// OKLCH
pub const OklchBinding = color_factory.createColorBinding(zignal.Oklch);
var oklch_getset = OklchBinding.generateGetSet();
var oklch_methods = OklchBinding.generateMethods();
pub var OklchType = c.PyTypeObject{
    .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
    .tp_name = "zignal.Oklch",
    .tp_basicsize = @sizeOf(OklchBinding.PyObjectType),
    .tp_dealloc = @ptrCast(&OklchBinding.dealloc),
    .tp_repr = @ptrCast(&OklchBinding.repr),
    .tp_str = @ptrCast(&OklchBinding.repr),
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = color_registry.getDocumentationString(zignal.Oklch).ptr,
    .tp_methods = @ptrCast(&oklch_methods),
    .tp_getset = @ptrCast(&oklch_getset),
    .tp_init = @ptrCast(&OklchBinding.init),
    .tp_new = @ptrCast(&OklchBinding.new),
    .tp_richcompare = @ptrCast(&OklchBinding.richcompare),
};

// LCH
pub const LchBinding = color_factory.createColorBinding(zignal.Lch);
var lch_getset = LchBinding.generateGetSet();
var lch_methods = LchBinding.generateMethods();
pub var LchType = c.PyTypeObject{
    .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
    .tp_name = "zignal.Lch",
    .tp_basicsize = @sizeOf(LchBinding.PyObjectType),
    .tp_dealloc = @ptrCast(&LchBinding.dealloc),
    .tp_repr = @ptrCast(&LchBinding.repr),
    .tp_str = @ptrCast(&LchBinding.repr),
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = color_registry.getDocumentationString(zignal.Lch).ptr,
    .tp_methods = @ptrCast(&lch_methods),
    .tp_getset = @ptrCast(&lch_getset),
    .tp_init = @ptrCast(&LchBinding.init),
    .tp_new = @ptrCast(&LchBinding.new),
    .tp_richcompare = @ptrCast(&LchBinding.richcompare),
};

// LMS
pub const LmsBinding = color_factory.createColorBinding(zignal.Lms);
var lms_getset = LmsBinding.generateGetSet();
var lms_methods = LmsBinding.generateMethods();
pub var LmsType = c.PyTypeObject{
    .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
    .tp_name = "zignal.Lms",
    .tp_basicsize = @sizeOf(LmsBinding.PyObjectType),
    .tp_dealloc = @ptrCast(&LmsBinding.dealloc),
    .tp_repr = @ptrCast(&LmsBinding.repr),
    .tp_str = @ptrCast(&LmsBinding.repr),
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = color_registry.getDocumentationString(zignal.Lms).ptr,
    .tp_methods = @ptrCast(&lms_methods),
    .tp_getset = @ptrCast(&lms_getset),
    .tp_init = @ptrCast(&LmsBinding.init),
    .tp_new = @ptrCast(&LmsBinding.new),
    .tp_richcompare = @ptrCast(&LmsBinding.richcompare),
};

// XYB
pub const XybBinding = color_factory.createColorBinding(zignal.Xyb);
var xyb_getset = XybBinding.generateGetSet();
var xyb_methods = XybBinding.generateMethods();
pub var XybType = c.PyTypeObject{
    .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
    .tp_name = "zignal.Xyb",
    .tp_basicsize = @sizeOf(XybBinding.PyObjectType),
    .tp_dealloc = @ptrCast(&XybBinding.dealloc),
    .tp_repr = @ptrCast(&XybBinding.repr),
    .tp_str = @ptrCast(&XybBinding.repr),
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = color_registry.getDocumentationString(zignal.Xyb).ptr,
    .tp_methods = @ptrCast(&xyb_methods),
    .tp_getset = @ptrCast(&xyb_getset),
    .tp_init = @ptrCast(&XybBinding.init),
    .tp_new = @ptrCast(&XybBinding.new),
    .tp_richcompare = @ptrCast(&XybBinding.richcompare),
};

// YCBCR
pub const YcbcrBinding = color_factory.createColorBinding(zignal.Ycbcr);
var ycbcr_getset = YcbcrBinding.generateGetSet();
var ycbcr_methods = YcbcrBinding.generateMethods();
pub var YcbcrType = c.PyTypeObject{
    .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
    .tp_name = "zignal.Ycbcr",
    .tp_basicsize = @sizeOf(YcbcrBinding.PyObjectType),
    .tp_dealloc = @ptrCast(&YcbcrBinding.dealloc),
    .tp_repr = @ptrCast(&YcbcrBinding.repr),
    .tp_str = @ptrCast(&YcbcrBinding.repr),
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = color_registry.getDocumentationString(zignal.Ycbcr).ptr,
    .tp_methods = @ptrCast(&ycbcr_methods),
    .tp_getset = @ptrCast(&ycbcr_getset),
    .tp_init = @ptrCast(&YcbcrBinding.init),
    .tp_new = @ptrCast(&YcbcrBinding.new),
    .tp_richcompare = @ptrCast(&YcbcrBinding.richcompare),
};

// ============================================================================
// REGISTRATION HELPER
// ============================================================================

/// Register all color types from the registry in one go
pub fn registerAllColorTypes(module: [*c]c.PyObject) !void {
    // Register each type - the order must match the registry
    try registerType(@ptrCast(module), "Rgb", @ptrCast(&RgbType));
    try registerType(@ptrCast(module), "Rgba", @ptrCast(&RgbaType));
    try registerType(@ptrCast(module), "Hsv", @ptrCast(&HsvType));
    try registerType(@ptrCast(module), "Hsl", @ptrCast(&HslType));
    try registerType(@ptrCast(module), "Lab", @ptrCast(&LabType));
    try registerType(@ptrCast(module), "Xyz", @ptrCast(&XyzType));
    try registerType(@ptrCast(module), "Oklab", @ptrCast(&OklabType));
    try registerType(@ptrCast(module), "Oklch", @ptrCast(&OklchType));
    try registerType(@ptrCast(module), "Lch", @ptrCast(&LchType));
    try registerType(@ptrCast(module), "Lms", @ptrCast(&LmsType));
    try registerType(@ptrCast(module), "Xyb", @ptrCast(&XybType));
    try registerType(@ptrCast(module), "Ycbcr", @ptrCast(&YcbcrType));
}

// ============================================================================
// CONVERSION HELPERS BETWEEN COLOR TYPES
// ============================================================================

/// Create a Python object from any zignal color type
pub fn createColorPyObject(color: anytype) ?*c.PyObject {
    const ColorType = @TypeOf(color);

    return switch (ColorType) {
        zignal.Rgb => RgbBinding.createPyObject(color, &RgbType),
        zignal.Rgba => RgbaBinding.createPyObject(color, &RgbaType),
        zignal.Hsv => HsvBinding.createPyObject(color, &HsvType),
        zignal.Hsl => HslBinding.createPyObject(color, &HslType),
        zignal.Lab => LabBinding.createPyObject(color, &LabType),
        zignal.Xyz => XyzBinding.createPyObject(color, &XyzType),
        zignal.Oklab => OklabBinding.createPyObject(color, &OklabType),
        zignal.Oklch => OklchBinding.createPyObject(color, &OklchType),
        zignal.Lch => LchBinding.createPyObject(color, &LchType),
        zignal.Lms => LmsBinding.createPyObject(color, &LmsType),
        zignal.Xyb => XybBinding.createPyObject(color, &XybType),
        zignal.Ycbcr => YcbcrBinding.createPyObject(color, &YcbcrType),
        else => null,
    };
}

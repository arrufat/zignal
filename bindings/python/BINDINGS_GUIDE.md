# Binding Zignal Functionality to Python

This guide shows how to expose new Zignal APIs to Python using the patterns and helpers in `bindings/python/src`.

## Overview

- Write bindings in Zig under `bindings/python/src/` grouped by domain:
  - `image/` (filters, transforms), `canvas.zig`, `matrix.zig`, `optimization.zig`, etc.
- Register types in the `type_table` in `main.zig` and enums in `enums.zig`.
- Build the bindings and regenerate the type stubs with `zig build python` (or `python-bindings` / `python-stubs` separately).
- Run tests with `uv run pytest` from `bindings/python`.

## Conventions

- Module: `const python = @import("python.zig");` is the primary module for helpers.
- Arguments Parsing: Use a declarative struct with `python.parseArgs`. This replaces manual `PyArg_ParseTupleAndKeywords` calls.
- Numeric validation: use `python` validators for consistent messages:
  - `validatePositive(T, value, name)`, `validateNonNegative(T, value, name)`, `validateRange(T, value, min, max, name)`
  - For floats requiring finiteness, check `std.math.isFinite(x)` first, then validate.
- Option structs: a Zig options argument becomes optional Python keyword arguments, one per field, with the same defaults. Give the `Params` fields default values (those are the optional arguments), build the options struct from them, and show the defaults in the metadata `.params` string. Example: `perlin.Options` → `perlin(x, y, z=0.0, amplitude=1.0, frequency=1.0, octaves=1, persistence=0.5, lacunarity=2.0)`.
- Type conversion: `python.parseArgs` converts most primitive types and enums; `python.parse(T, obj)` converts a single object (points, rectangles, ...). `python.parsePointPairs` reads the paired point lists the transforms take.
- Exceptions: Type errors → `TypeError`; range/domain → `ValueError`; resource/IO → `MemoryError`, `FileNotFoundError`, etc. Use `python.setValueError` or `python.setMemoryError`.
- Enums: add an entry to `registry` in `enums.zig` (`main.zig` registers it and the stub generator writes it); parse with `enum_utils.pyToEnum`. For `union(enum)` (e.g., `Interpolation`), parse the tag with `enum_utils.pyToUnionTag` and map it to a value.
- Threading: pass `python.io` wherever a Zig API takes `io: Io`, and run heavy work through `python.withoutGil` so other Python threads keep running.
- Images: when producing a new image, return via `moveImageToPython(out)` which adopts ownership and sets references; preserve borrowed semantics for views/NumPy.

## Naming

The Zig API is namespaced (`zignal.image.BorderMode`, `zignal.optimization.Policy`); the Python API is flat (`zignal.BorderMode`, `zignal.OptimizationPolicy`). Python names are the Zig qualified names, flattened:

- Keep the Zig name when it is unambiguous on its own: `image.BorderMode` → `BorderMode`.
- Fold the namespace back in when the bare name would be too generic at Python's top level: `optimization.Policy` → `OptimizationPolicy`, `stats.Running` → `RunningStats`.
- Enum class names default to the Zig type's simple name; set `.name` on the `enums.zig` registry entry to override it (see `OptimizationPolicy`). Types and functions are named explicitly where they are registered.

## Adding a New Method (example)

`Image.box_blur(radius: int)` wraps `Image(T).boxBlur`. New methods follow the same shape:

1) Implement the binding in `bindings/python/src/image/filtering.zig`:

```zig
pub fn image_box_blur(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = python.safeCast(ImageObject, self_obj);
    python.ensureInitialized(self, "py_image", "Image not initialized") catch return null;

    const Params = struct { radius: c_long };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const radius = python.validateNonNegative(u32, params.radius, "radius") catch return null;

    return self.py_image.?.dispatch(.{radius}, struct {
        fn apply(img: anytype, r: u32) ?*c.PyObject {
            const out = @TypeOf(img.*).initLike(allocator, img.*) catch {
                python.setMemoryError("image operation");
                return null;
            };
            python.withoutGil(@TypeOf(img.*).boxBlur, .{ img.*, python.io, allocator, out, r }) catch {
                python.setMemoryError("image operation");
                return null;
            };
            return @ptrCast(moveImageToPython(out) orelse return null);
        }
    }.apply);
}
```

Put the docstring next to it as `image_box_blur_doc`.

2) Add an entry to the matching method group in `image.zig`, which feeds `image_methods_metadata` and from there both the method table and the `.pyi` stubs:

```zig
.{
    .name = "box_blur",
    .meth = @ptrCast(&filtering.image_box_blur),
    .flags = c.METH_VARARGS | c.METH_KEYWORDS,
    .doc = filtering.image_box_blur_doc,
    .params = "self, radius: int",
    .returns = "Image",
},
```

3) Run:

```bash
zig build python
cd bindings/python && uv run pytest
```

## Adding a New Type

1) Define the object struct and methods in a new Zig file under `bindings/python/src/`.

2) Register in `bindings/python/src/main.zig` by adding it to the `type_table`:

```zig
const type_table = [_]TypeReg{
    // ...
    .{ .name = "MyType", .ty = @ptrCast(&my_module.MyType) },
};
```

3) If the type has an associated enum, add it to `registry` in `enums.zig` (with a `.name` override if needed, see [Naming](#naming)) and parse with `enum_utils.pyToEnum` in call sites.

## Stubs and Docs

- Stubs are generated from compile‑time metadata arrays (e.g., `*_methods_metadata`). Keep metadata updated as you add methods and properties.
- API docs are published from the generated stubs (see CI). For local inspection: `zig build python-stubs` and inspect `bindings/python/zignal/_zignal.pyi`.

## Testing

- Prefer adding tests in `bindings/python/tests/test_*.py`.
- Run: `uv run pytest`.

## Troubleshooting

- If Python headers/libs aren’t auto‑detected: set `PYTHON_INCLUDE_DIR`, `PYTHON_LIBS_DIR`, `PYTHON_LIB_NAME`.
- Ensure Python 3.10 or newer is on PATH; the bindings target 3.10–3.14.

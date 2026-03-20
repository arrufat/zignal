# Binding Zignal Functionality to Python

This guide shows how to expose new Zignal APIs to Python using the patterns and helpers in `bindings/python/src`.

## Overview

- Write bindings in Zig under `bindings/python/src/` grouped by domain:
  - `image/` (filters, transforms), `canvas.zig`, `matrix.zig`, `optimization.zig`, etc.
- Register types/enums in `src/main.zig`.
- Generate type stubs with `zig build python-stubs`.
- Run tests with `uv run pytest`.

## Conventions

- Module: `const python = @import("python.zig");` is the primary module for helpers.
- Arguments Parsing: Use a declarative struct with `python.parseArgs`. This replaces manual `PyArg_ParseTupleAndKeywords` calls.
- Numeric validation: use `python` validators for consistent messages:
  - `validatePositive(T, value, name)`, `validateNonNegative(T, value, name)`, `validateRange(T, value, min, max, name)`
  - For floats requiring finiteness, check `std.math.isFinite(x)` first, then validate.
- Type conversion: `python.parseArgs` automatically converts most primitive types and enums. For composites, use `parsePointTuple`, `parsePointList`, `parseRectangle`.
- Exceptions: Type errors → `TypeError`; range/domain → `ValueError`; resource/IO → `MemoryError`, `FileNotFoundError`, etc. Use `python.setValueError` or `python.setMemoryError`.
- Enums: register with `enum_utils.registerEnum` in `main.zig`; parse with `enum_utils.pyToEnum`. For `union(enum)` (e.g., `Interpolation`), map tags with `enum_utils.longToUnionTag` + a small tag→value mapper.
- Images: when producing a new image, return via `moveImageToPython(out)` which adopts ownership and sets references; preserve borrowed semantics for views/NumPy.

## Adding a New Method (example)

Suppose Zignal adds `Image(T).medianBlur(radius: usize)`. To expose `image.median_blur(radius: int)`:

1) Implement binding in `bindings/python/src/image/filtering.zig`:

```zig
pub fn image_median_blur(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = python.safeCast(ImageObject, self_obj);
    python.ensureInitialized(self, "py_image", "Image not initialized") catch return null;

    const Params = struct { radius: c_long };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const radius = python.validateNonNegative(u32, params.radius, "radius") catch return null;

    return self.py_image.?.dispatch(.{radius}, struct {
        fn apply(img: anytype, r: u32) ?*c.PyObject {
            var out = @TypeOf(img.*).empty;
            img.medianBlur(allocator, r, &out) catch |err| {
                switch (err) {
                    error.InvalidRadius => python.setValueError("radius must be > 0", .{}),
                    error.UnsupportedPixelType => python.setValueError("median blur requires u8, RGB, or RGBA images", .{}),
                    else => python.setMemoryError("image operation"),
                }
                return null;
            };
            return @ptrCast(moveImageToPython(out) orelse return null);
        }
    });
}
```

2) Add to stub metadata in the same file so `.pyi` stubs include the method signature and docstring.

3) Update `image_methods_metadata` (if needed) and ensure it is exported by `src/main.zig` via the module function metadata aggregation.

4) Run:

```bash
zig build python-bindings
uv run pytest
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

3) If the type has an associated enum, register it via `enum_utils.registerEnum` in `main.zig` and parse with `enum_utils.pyToEnum` in call sites.

## Stubs and Docs

- Stubs are generated from compile‑time metadata arrays (e.g., `*_methods_metadata`). Keep metadata updated as you add methods and properties.
- API docs are published from the generated stubs (see CI). For local inspection: `zig build python-stubs` and inspect `bindings/python/zignal/_zignal.pyi`.

## Testing

- Prefer adding tests in `bindings/python/tests/test_*.py`.
- Run: `uv run pytest`.

## Troubleshooting

- If Python headers/libs aren’t auto‑detected: set `PYTHON_INCLUDE_DIR`, `PYTHON_LIBS_DIR`, `PYTHON_LIB_NAME`.
- Ensure Python 3.10 or newer is on PATH; the bindings target 3.10–3.13.

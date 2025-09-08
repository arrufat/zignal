# Binding Zignal Functionality to Python

This guide shows how to expose new Zignal APIs to Python using the patterns and helpers in `bindings/python/src`.

## Overview

- Write bindings in Zig under `bindings/python/src/` grouped by domain:
  - `image/` (filters, transforms), `canvas.zig`, `matrix.zig`, `optimization.zig`, etc.
- Register types/enums in `src/main.zig`.
- Generate type stubs with `zig build python-stubs`.
- Run tests with `cd bindings/python && uv run pytest -q`.

## Conventions

- Keywords: build with `comptime py_utils.kw(&.{ ... })` and pass as `@ptrCast(@constCast(&kw))` to `PyArg_ParseTupleAndKeywords`.
- Numeric validation: use `py_utils` validators for consistent messages:
  - `validatePositive(T, value, name)`, `validateNonNegative(T, value, name)`, `validateRange(T, value, min, max, name)`
  - For floats requiring finiteness, check `std.math.isFinite(x)` first, then validate.
- Type conversion: for primitives use `convertFromPython`, `convertPythonArgument`, `convertWithValidation`; for composites use `parsePointTuple`, `parsePointList`, `parseRectangle`.
- Exceptions: Type errors → `TypeError`; range/domain → `ValueError`; resource/IO → `MemoryError`, `FileNotFoundError`, etc. Use `py_utils.setErrorWithPath` for filesystem paths.
- Enums: register with `enum_utils.registerEnum` in `main.zig`; parse with `enum_utils.pyToEnum`. For `union(enum)` (e.g., `Interpolation`), map tags with `enum_utils.longToUnionTag` + a small tag→value mapper.
- Images: when producing a new image, return via `moveImageToPython(out)` which adopts ownership and sets references; preserve borrowed semantics for views/NumPy.

## Adding a New Method (example)

Suppose Zignal adds `Image(T).medianBlur(radius: usize)`. To expose `image.median_blur(radius: int)`:

1) Implement binding in `bindings/python/src/image/filtering.zig`:

```zig
pub fn image_median_blur(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    var radius_long: c_long = 0;
    const kw = comptime py_utils.kw(&.{ "radius" });
    if (c.PyArg_ParseTupleAndKeywords(args, kwds, "l", @ptrCast(@constCast(&kw)), &radius_long) == 0) return null;
    const radius = py_utils.validateNonNegative(u32, radius_long, "radius") catch return null;

    if (self.py_image) |pimg| switch (pimg.data) {
        inline else => |img| {
            var out = @TypeOf(img).empty;
            img.medianBlur(allocator, &out, @intCast(radius)) catch {
                c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
                return null;
            };
            return @ptrCast(moveImageToPython(out) orelse return null);
        },
    };

    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}
```

2) Add to stub metadata in the same file so `.pyi` stubs include the method signature and docstring.

3) Update `image_methods_metadata` (if needed) and ensure it is exported by `src/main.zig` via the module function metadata aggregation.

4) Run:

```bash
zig build python-bindings
cd bindings/python && uv run pytest -q
zig build python-stubs
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
- Run: `cd bindings/python && uv run pytest -q`.

## Troubleshooting

- If Python headers/libs aren’t auto‑detected: set `PYTHON_INCLUDE_DIR`, `PYTHON_LIBS_DIR`, `PYTHON_LIB_NAME`.
- If build cache permissions fail in sandboxed environments, rerun without sandboxing or with proper cache dirs.


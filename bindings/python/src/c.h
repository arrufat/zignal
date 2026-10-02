#define PY_SSIZE_T_CLEAN
// aro crashes on CPython's pyatomic_std.h (atomic_load on an _Atomic pointer);
// force the GCC builtin backend until it is fixed upstream.
#define _Py_USE_GCC_BUILTIN_ATOMICS 1
#include <Python.h>

const std = @import("std");

const zignal = @import("zignal");
const RunningStats = zignal.RunningStats;

const py_utils = @import("py_utils.zig");
const allocator = py_utils.ctx.allocator;
pub const registerType = py_utils.registerType;
const c = py_utils.c;
const stub_metadata = @import("stub_metadata.zig");

const RunningStatsF64 = RunningStats(f64);

pub const RunningStatsObject = extern struct {
    ob_base: c.PyObject,
    stats_ptr: ?*RunningStatsF64,
};

const running_stats_new = py_utils.genericNew(RunningStatsObject);

fn running_stats_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    _ = args;
    _ = kwds;
    const self = py_utils.safeCast(RunningStatsObject, self_obj);

    const stats_ptr = allocator.create(RunningStatsF64) catch {
        py_utils.setMemoryError("RunningStats");
        return -1;
    };
    stats_ptr.* = RunningStatsF64.init();
    self.stats_ptr = stats_ptr;

    return 0;
}

fn runningStatsDeinit(self: *RunningStatsObject) void {
    if (self.stats_ptr) |ptr| {
        allocator.destroy(ptr);
    }
    self.stats_ptr = null;
}

const running_stats_dealloc = py_utils.genericDealloc(RunningStatsObject, runningStatsDeinit);

fn running_stats_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(RunningStatsObject, self_obj);

    if (self.stats_ptr) |ptr| {
        const stats = ptr.*;
        var buffer: [256]u8 = undefined;
        const repr = std.fmt.bufPrintZ(&buffer, "RunningStats(n={d}, mean={d:.6}, std_dev={d:.6})", .{
            stats.currentN(),
            stats.mean(),
            stats.stdDev(),
        }) catch "RunningStats(...)";
        return c.PyUnicode_FromString(repr.ptr);
    }

    return c.PyUnicode_FromString("RunningStats(uninitialized)");
}

const running_stats_add_doc =
    \\Add a single sample to the running statistics.
    \\
    \\## Parameters
    \\- `value` (float): Sample value to add.
    \\
    \\## Examples
    \\```python
    \\stats = RunningStats()
    \\stats.add(1.5)
    \\```
;

fn running_stats_add(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const stats_ptr = py_utils.unwrap(RunningStatsObject, "stats_ptr", self_obj, "RunningStats") orelse return null;

    const Params = struct {
        value: f64,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    stats_ptr.add(@floatCast(params.value));
    return py_utils.getPyNone();
}

const running_stats_extend_doc =
    \\Add multiple samples to the running statistics.
    \\
    \\## Parameters
    \\- `values` (Iterable[float]): Iterable of numeric samples.
    \\
    \\## Examples
    \\```python
    \\stats = RunningStats()
    \\stats.extend([1.0, 2.5, 3.7])
    \\```
;

fn running_stats_extend(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const stats_ptr = py_utils.unwrap(RunningStatsObject, "stats_ptr", self_obj, "RunningStats") orelse return null;

    const Params = struct {
        values: ?*c.PyObject,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const values_obj = params.values;
    if (values_obj == null) {
        py_utils.setTypeError("Iterable of floats", null);
        return null;
    }

    const iter = c.PyObject_GetIter(values_obj);
    if (iter == null) {
        c.PyErr_SetString(c.PyExc_TypeError, "values must be an iterable of numbers");
        return null;
    }
    defer c.Py_DECREF(iter);

    while (true) {
        const item = c.PyIter_Next(iter);
        if (item == null) {
            if (c.PyErr_Occurred() != null) {
                return null;
            }
            break;
        }
        const value = c.PyFloat_AsDouble(item);
        c.Py_DECREF(item);

        if (value == -1 and c.PyErr_Occurred() != null) {
            c.PyErr_SetString(c.PyExc_TypeError, "values must contain only numbers");
            return null;
        }

        stats_ptr.add(@floatCast(value));
    }

    return py_utils.getPyNone();
}

const running_stats_clear_doc =
    \\Reset all accumulated statistics.
    \\
    \\## Examples
    \\```python
    \\stats = RunningStats()
    \\stats.add(5.0)
    \\stats.clear()
    \\print(stats.count)  # 0
    \\```
;

fn running_stats_clear(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const stats_ptr = py_utils.unwrap(RunningStatsObject, "stats_ptr", self_obj, "RunningStats") orelse return null;
    stats_ptr.clear();
    return py_utils.getPyNone();
}

const running_stats_scale_doc =
    \\Standardize a value using the accumulated statistics.
    \\
    \\Returns `(value - mean) / std_dev`. If the standard deviation is zero
    \\(e.g., fewer than two samples or zero variance), this returns 0.0.
    \\
    \\## Parameters
    \\- `value` (float): Value to scale.
    \\
    \\## Returns
    \\float: Scaled value.
;

fn running_stats_scale(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const stats_ptr = py_utils.unwrap(RunningStatsObject, "stats_ptr", self_obj, "RunningStats") orelse return null;

    const Params = struct {
        value: f64,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const scaled = stats_ptr.scale(params.value);
    return c.PyFloat_FromDouble(scaled);
}

const running_stats_combine_doc =
    \\Combine with another RunningStats instance and return the aggregated result.
    \\
    \\The current object is not modified; a new RunningStats instance is returned.
    \\
    \\## Parameters
    \\- `other` (RunningStats): Another set of statistics to merge.
    \\
    \\## Returns
    \\RunningStats: Combined statistics.
;

fn running_stats_combine(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const stats_ptr = py_utils.unwrap(RunningStatsObject, "stats_ptr", self_obj, "RunningStats") orelse return null;

    const Params = struct {
        other: ?*c.PyObject,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const other_obj = params.other orelse {
        py_utils.setTypeError("RunningStats instance", null);
        return null;
    };

    if (py_utils.getPyType(other_obj) != @as(*c.PyTypeObject, @ptrCast(&RunningStatsType))) {
        py_utils.setTypeError("RunningStats instance", other_obj);
        return null;
    }

    const other_ptr = py_utils.unwrap(RunningStatsObject, "stats_ptr", other_obj, "RunningStats") orelse return null;

    const combined = stats_ptr.combine(other_ptr.*);

    const result = c.PyObject_CallObject(@ptrCast(&RunningStatsType), null) orelse return null;
    const result_ptr = py_utils.unwrap(RunningStatsObject, "stats_ptr", result, "RunningStats") orelse {
        c.Py_DECREF(result);
        return null;
    };
    result_ptr.* = combined;
    return result;
}

pub const running_stats_methods_metadata = [_]stub_metadata.MethodWithMetadata{
    .{
        .name = "add",
        .meth = @ptrCast(&running_stats_add),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = running_stats_add_doc,
        .params = "self, value: float",
        .returns = "None",
    },
    .{
        .name = "extend",
        .meth = @ptrCast(&running_stats_extend),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = running_stats_extend_doc,
        .params = "self, values: Iterable[float]",
        .returns = "None",
    },
    .{
        .name = "clear",
        .meth = @ptrCast(&running_stats_clear),
        .flags = c.METH_VARARGS,
        .doc = running_stats_clear_doc,
        .params = "self",
        .returns = "None",
    },
    .{
        .name = "scale",
        .meth = @ptrCast(&running_stats_scale),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = running_stats_scale_doc,
        .params = "self, value: float",
        .returns = "float",
    },
    .{
        .name = "combine",
        .meth = @ptrCast(&running_stats_combine),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = running_stats_combine_doc,
        .params = "self, other: RunningStats",
        .returns = "RunningStats",
    },
};

var running_stats_methods = stub_metadata.toPyMethodDefArray(&running_stats_methods_metadata);

fn running_stats_count_getter(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const stats_ptr = py_utils.unwrap(RunningStatsObject, "stats_ptr", self_obj, "RunningStats") orelse return null;
    return c.PyLong_FromUnsignedLongLong(@intCast(stats_ptr.currentN()));
}

fn running_stats_sum_getter(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const stats_ptr = py_utils.unwrap(RunningStatsObject, "stats_ptr", self_obj, "RunningStats") orelse return null;
    return c.PyFloat_FromDouble(stats_ptr.getSum());
}

fn running_stats_mean_getter(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const stats_ptr = py_utils.unwrap(RunningStatsObject, "stats_ptr", self_obj, "RunningStats") orelse return null;
    return c.PyFloat_FromDouble(stats_ptr.mean());
}

fn running_stats_variance_getter(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const stats_ptr = py_utils.unwrap(RunningStatsObject, "stats_ptr", self_obj, "RunningStats") orelse return null;
    return c.PyFloat_FromDouble(stats_ptr.variance());
}

fn running_stats_stddev_getter(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const stats_ptr = py_utils.unwrap(RunningStatsObject, "stats_ptr", self_obj, "RunningStats") orelse return null;
    return c.PyFloat_FromDouble(stats_ptr.stdDev());
}

fn running_stats_skewness_getter(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const stats_ptr = py_utils.unwrap(RunningStatsObject, "stats_ptr", self_obj, "RunningStats") orelse return null;
    return c.PyFloat_FromDouble(stats_ptr.skewness());
}

fn running_stats_kurtosis_getter(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const stats_ptr = py_utils.unwrap(RunningStatsObject, "stats_ptr", self_obj, "RunningStats") orelse return null;
    return c.PyFloat_FromDouble(stats_ptr.exKurtosis());
}

fn running_stats_min_getter(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const stats_ptr = py_utils.unwrap(RunningStatsObject, "stats_ptr", self_obj, "RunningStats") orelse return null;
    return c.PyFloat_FromDouble(stats_ptr.min());
}

fn running_stats_max_getter(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const stats_ptr = py_utils.unwrap(RunningStatsObject, "stats_ptr", self_obj, "RunningStats") orelse return null;
    return c.PyFloat_FromDouble(stats_ptr.max());
}

pub const running_stats_properties_metadata = [_]stub_metadata.PropertyWithMetadata{
    .{
        .name = "count",
        .get = running_stats_count_getter,
        .set = null,
        .doc = "Number of samples seen so far.",
        .type = "int",
    },
    .{
        .name = "sum",
        .get = running_stats_sum_getter,
        .set = null,
        .doc = "Sum of all sample values.",
        .type = "float",
    },
    .{
        .name = "mean",
        .get = running_stats_mean_getter,
        .set = null,
        .doc = "Sample mean.",
        .type = "float",
    },
    .{
        .name = "variance",
        .get = running_stats_variance_getter,
        .set = null,
        .doc = "Unbiased sample variance.",
        .type = "float",
    },
    .{
        .name = "std_dev",
        .get = running_stats_stddev_getter,
        .set = null,
        .doc = "Sample standard deviation.",
        .type = "float",
    },
    .{
        .name = "skewness",
        .get = running_stats_skewness_getter,
        .set = null,
        .doc = "Sample skewness (0 if fewer than 3 samples).",
        .type = "float",
    },
    .{
        .name = "ex_kurtosis",
        .get = running_stats_kurtosis_getter,
        .set = null,
        .doc = "Excess kurtosis (0 if fewer than 4 samples).",
        .type = "float",
    },
    .{
        .name = "min",
        .get = running_stats_min_getter,
        .set = null,
        .doc = "Minimum observed value (0 if no samples).",
        .type = "float",
    },
    .{
        .name = "max",
        .get = running_stats_max_getter,
        .set = null,
        .doc = "Maximum observed value (0 if no samples).",
        .type = "float",
    },
};

var running_stats_getset = stub_metadata.toPyGetSetDefArray(&running_stats_properties_metadata);

const running_stats_class_doc =
    \\Online statistics accumulator using Welford's algorithm.
    \\
    \\Maintains numerically stable estimates of mean, variance, skewness,
    \\and excess kurtosis in a single pass.
;

pub const running_stats_special_methods_metadata = [_]stub_metadata.MethodInfo{
    .{
        .name = "__init__",
        .params = "self",
        .returns = "None",
        .doc = running_stats_class_doc,
    },
};

pub var RunningStatsType = py_utils.buildTypeObject(.{
    .name = "zignal.RunningStats",
    .basicsize = @sizeOf(RunningStatsObject),
    .doc = running_stats_class_doc,
    .methods = @ptrCast(&running_stats_methods),
    .getset = @ptrCast(&running_stats_getset),
    .new = running_stats_new,
    .init = running_stats_init,
    .dealloc = running_stats_dealloc,
    .repr = running_stats_repr,
});

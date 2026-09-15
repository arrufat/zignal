const zignal = @import("zignal");
const clustering = zignal.clustering;
const Matrix = zignal.Matrix;

const matrix_module = @import("matrix.zig");
const MatrixObject = matrix_module.MatrixObject;
const python = @import("python.zig");
const allocator = python.allocator;
const c = python.c;

/// Only read for its `iterations` and `seed` field defaults, so the binding cannot drift from the
/// library; `threshold` is required, so any value will do to instantiate the struct.
const option_defaults: clustering.Options = .{ .threshold = 0 };

const chinese_whispers_clustering_doc =
    \\Cluster embeddings by connecting every pair closer than `threshold`.
    \\
    \\Runs the Chinese Whispers label propagation algorithm over that graph, discovering the
    \\number of clusters rather than taking it as input. An embedding with no neighbour within
    \\`threshold` ends up alone in its own cluster.
    \\
    \\## Parameters
    \\- `embeddings`: a `Matrix`, or a sequence of equal-length float sequences, one row per item
    \\- `threshold`: maximum Euclidean distance for two embeddings to be connected
    \\- `iterations`: passes over the graph (default 100)
    \\- `seed`: seed for the node visit order (default 0)
    \\
    \\## Returns
    \\A list with one cluster id per embedding, numbered contiguously from 0.
    \\
    \\## Examples
    \\```python
    \\import zignal
    \\
    \\embeddings = [[0.0, 0.0], [0.1, 0.1], [9.0, 9.0], [9.1, 9.1]]
    \\labels = zignal.chinese_whispers_clustering(embeddings, 1.0)
    \\print(labels)  # [0, 0, 1, 1]
    \\```
;

fn chinese_whispers_clustering(self: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = self;
    const Params = struct {
        embeddings: ?*c.PyObject,
        threshold: f64,
        iterations: u32 = option_defaults.iterations,
        seed: u64 = option_defaults.seed,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    // Either borrowed from a Matrix argument or built from a nested sequence.
    var owned: ?*Matrix(f64) = null;
    defer python.destroyHeapObject(Matrix(f64), owned);
    const matrix: Matrix(f64) = if (c.PyObject_IsInstance(params.embeddings, @ptrCast(&matrix_module.MatrixType)) == 1)
        (python.unwrap(MatrixObject, "matrix_ptr", params.embeddings, "Matrix") orelse return null).*
    else blk: {
        owned = matrix_module.matrixFromSequence(params.embeddings) catch return null;
        break :blk owned.?.*;
    };

    const embeddings = allocator.alloc([]const f64, matrix.rows) catch {
        python.setMemoryError("embeddings");
        return null;
    };
    defer allocator.free(embeddings);
    for (embeddings, 0..) |*row, i| row.* = matrix.items[i * matrix.cols ..][0..matrix.cols];

    const labels = allocator.alloc(u32, embeddings.len) catch {
        python.setMemoryError("labels");
        return null;
    };
    defer allocator.free(labels);

    _ = python.withoutGil(clustering.chineseWhispers, .{
        f64,
        python.io,
        allocator,
        embeddings,
        labels,
        clustering.Options{ .threshold = params.threshold, .iterations = params.iterations, .seed = params.seed },
    }) catch |err| switch (err) {
        error.InvalidThreshold => {
            python.setValueError("threshold must be finite and non-negative", .{});
            return null;
        },
        else => {
            python.mapZigError(err, "chinese_whispers_clustering");
            return null;
        },
    };

    return python.listFromSlice(u32, labels);
}

pub const module_functions_metadata = [_]python.FunctionWithMetadata{
    .{
        .name = "chinese_whispers_clustering",
        .meth = @ptrCast(&chinese_whispers_clustering),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = chinese_whispers_clustering_doc,
        .params = "embeddings: Matrix | Sequence[Sequence[float]], threshold: float, iterations: int = 100, seed: int = 0",
        .returns = "list[int]",
    },
};

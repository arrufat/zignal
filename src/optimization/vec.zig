//! Small vector helpers on []f64 shared by the optimization modules.

pub fn dot(a: []const f64, b: []const f64) f64 {
    var s: f64 = 0;
    for (a, b) |x, y| s += x * y;
    return s;
}

pub fn norm(a: []const f64) f64 {
    return @sqrt(dot(a, a));
}

pub fn distSq(a: []const f64, b: []const f64) f64 {
    var s: f64 = 0;
    for (a, b) |x, y| {
        const d = x - y;
        s += d * d;
    }
    return s;
}

pub fn dist(a: []const f64, b: []const f64) f64 {
    return @sqrt(distSq(a, b));
}

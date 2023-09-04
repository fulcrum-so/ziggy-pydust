const py = @import("pydust");

pub fn double(args: *const extern struct { x: py.PyLong }) !i64 {
    return try args.x.as(i64) * 2;
}

comptime {
    py.module(@This());
}
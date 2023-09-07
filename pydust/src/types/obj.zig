const std = @import("std");
const ffi = @import("../ffi.zig");
const str = @import("str.zig");
const py = @import("../pydust.zig");
const tramp = @import("../trampoline.zig");
const PyError = @import("../errors.zig").PyError;

/// PyTypeObject exists in Limited API only as an opaque pointer.
pub const PyType = extern struct {
    obj: PyObject,

    pub fn getQualifiedName(self: PyType) !py.PyString {
        return py.PyString.of(ffi.PyType_GetQualName(self.obj.py) orelse return PyError.Propagate);
    }
};

pub const PyObject = extern struct {
    py: *ffi.PyObject,

    pub fn incref(self: PyObject) void {
        ffi.Py_INCREF(self.py);
    }

    pub fn decref(self: PyObject) void {
        ffi.Py_DECREF(self.py);
    }

    /// Call this object without any arguments.
    pub fn call0(self: PyObject) !PyObject {
        return .{ .py = ffi.PyObject_CallNoArgs(self.py) orelse return PyError.Propagate };
    }

    /// Call this object with the given args and kwargs.
    pub fn call(self: PyObject, comptime R: type, args: anytype, kwargs: anytype) !R {
        var argsPy: py.PyTuple = undefined;
        if (@typeInfo(@TypeOf(args)) == .Optional and args == null) {
            argsPy = py.PyTuple.new(0);
        } else {
            argsPy = py.PyTuple.checked(try py.create(args));
        }
        defer argsPy.decref();

        // FIXME(ngates): avoid creating empty dict for kwargs
        const kwargsPy: py.PyDict = undefined;
        if (@typeInfo(@TypeOf(kwargs)) == .Optional and kwargs == null) {
            kwargsPy = py.PyDict.new(0);
        } else {
            const kwobj = try py.create(kwargs);
            if (try py.len(kwobj) == 0) {
                kwobj.decref();
                kwargsPy = py.PyDict.new();
            } else {
                kwargsPy = py.PyDict.checked(kwobj);
            }
        }
        defer kwargsPy.decref();

        const result = ffi.PyObject_Call(self.py, argsPy.obj.py, kwargsPy.obj.py) orelse return PyError.Propagate;
        return tramp.Trampoline(R).unwrap(.{ .py = result });
    }

    pub fn get(self: PyObject, attr: [:0]const u8) !PyObject {
        return .{ .py = ffi.PyObject_GetAttrString(self.py, attr) orelse return PyError.Propagate };
    }

    // See: https://docs.python.org/3/c-api/buffer.html#buffer-request-types
    pub fn getBuffer(self: py.PyObject, out: *py.PyBuffer, flags: c_int) !void {
        if (ffi.PyObject_CheckBuffer(self.py) != 1) {
            return py.BufferError.raise("object does not support buffer interface");
        }
        if (ffi.PyObject_GetBuffer(self.py, @ptrCast(out), flags) != 0) {
            // Error is already raised.
            return PyError.Propagate;
        }
    }

    pub fn set(self: PyObject, attr: [:0]const u8, value: PyObject) !PyObject {
        if (ffi.PyObject_SetAttrString(self.py, attr, value.py) < 0) {
            return PyError.Propagate;
        }
        return self;
    }

    pub fn del(self: PyObject, attr: [:0]const u8) !PyObject {
        if (ffi.PyObject_DelAttrString(self.py, attr) < 0) {
            return PyError.Propagate;
        }
        return self;
    }

    pub fn repr(self: PyObject) !PyObject {
        return .{ .py = ffi.PyObject_Repr(@ptrCast(self)) orelse return PyError.Propagate };
    }
};

pub fn PyObjectMixin(comptime name: []const u8, comptime prefix: []const u8, comptime Self: type) type {
    const PyCheck = @field(ffi, prefix ++ "_Check");

    return struct {
        /// Checked conversion from a PyObject.
        pub fn checked(obj: py.PyObject) !Self {
            if (PyCheck(obj.py) == 0) {
                return py.TypeError.raise("expected " ++ name);
            }
            return .{ .obj = obj };
        }

        /// Unchecked conversion from a PyObject.
        pub fn unchecked(obj: py.PyObject) Self {
            return .{ .obj = obj };
        }

        /// Increment the object's refcnt.
        pub fn incref(self: Self) void {
            self.obj.incref();
        }

        /// Decrement the object's refcnt.
        pub fn decref(self: Self) void {
            self.obj.decref();
        }
    };
}

test "call" {
    py.initialize();
    defer py.finalize();

    const math = try py.import("math");
    defer math.decref();

    const pow = try math.get("pow");
    const result = try pow.call(f32, .{ 2, 3 }, .{});

    try std.testing.expectEqual(@as(f32, 8.0), result);
}

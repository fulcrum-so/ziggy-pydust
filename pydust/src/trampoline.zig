// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//         http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

/// Utilities for bouncing CPython calls into Zig functions and back again.
const std = @import("std");
const Type = std.builtin.Type;
const ffi = @import("ffi.zig");
const py = @import("pydust.zig");
const State = @import("discovery.zig").State;
const funcs = @import("functions.zig");
const pytypes = @import("pytypes.zig");
const PyError = @import("errors.zig").PyError;

/// Generate functions to convert comptime-known Zig types to/from py.PyObject.
pub fn Trampoline(comptime T: type) type {
    // Catch and handle comptime literals
    if (T == comptime_int) {
        return Trampoline(i64);
    }
    if (T == comptime_float) {
        return Trampoline(f64);
    }

    return struct {
        /// Recursively decref any PyObjects found in a native Zig type.
        pub inline fn decref_objectlike(obj: T) void {
            if (isObjectLike()) {
                asObject(obj).decref();
                return;
            }
            switch (@typeInfo(T)) {
                .ErrorUnion => |e| {
                    Trampoline(e.payload).decref_objectlike(obj catch return);
                },
                .Optional => |o| {
                    if (obj) |object| Trampoline(o.child).decref_objectlike(object);
                },
                .Struct => |s| {
                    inline for (s.fields) |f| {
                        Trampoline(f.type).decref_objectlike(@field(obj, f.name));
                    }
                },
                // Explicit compile-error for other "container" types just to force us to handle them in the future.
                .Pointer, .Array, .Union => {
                    @compileError("Object decref not supported for type: " ++ @typeName(T));
                },
                else => {},
            }
        }

        /// Wraps an object that already represents an existing Python object.
        /// In other words, Zig primitive types are not supported.
        pub inline fn asObject(obj: T) py.PyObject {
            switch (@typeInfo(T)) {
                .Pointer => |p| {
                    // The object is an ffi.PyObject
                    if (p.child == ffi.PyObject) {
                        return .{ .py = obj };
                    }

                    if (State.findDefinition(p.child)) |def| {
                        // If the pointer is for a Pydust class
                        if (def.type == .class) {
                            const PyType = pytypes.PyTypeStruct(p.child);
                            const ffiObject: *ffi.PyObject = @constCast(@ptrCast(@fieldParentPtr(PyType, "state", obj)));
                            return .{ .py = ffiObject };
                        }

                        // If the pointer is for a Pydust module
                        if (def.type == .module) {
                            @compileError("Cannot currently return modules");
                        }
                    }
                },
                .Struct => {
                    // Support all extensions of py.PyObject, e.g. py.PyString, py.PyFloat
                    if (@hasField(T, "obj") and @hasField(std.meta.fieldInfo(T, .obj).type, "py")) {
                        return obj.obj;
                    }
                    if (T == py.PyObject) {
                        return obj;
                    }
                },
                .Optional => |o| return if (obj) |objP| Trampoline(o.child).asObject(objP) else std.debug.panic("Can't convert null to an object", .{}),
                inline else => {},
            }
            @compileError("Cannot convert into PyObject: " ++ @typeName(T));
        }

        inline fn isObjectLike() bool {
            switch (@typeInfo(T)) {
                .Pointer => |p| {
                    // The object is an ffi.PyObject
                    if (p.child == ffi.PyObject) {
                        return true;
                    }

                    if (State.findDefinition(p.child)) |_| {
                        return true;
                    }
                },
                .Struct => {
                    // Support all extensions of py.PyObject, e.g. py.PyString, py.PyFloat
                    if (@hasField(T, "obj") and @hasField(std.meta.fieldInfo(T, .obj).type, "py")) {
                        return true;
                    }

                    // Support py.PyObject
                    if (T == py.PyObject) {
                        return true;
                    }
                },
                inline else => {},
            }
            return false;
        }

        /// Wraps a Zig object into a new Python object.
        /// The result should be treated like a new reference.
        pub inline fn wrap(obj: T) PyError!py.PyObject {
            // Check the user is not accidentally returning a Pydust class or Module without a pointer
            if (State.findDefinition(T) != null) {
                @compileError("Pydust objects can only be returned as pointers");
            }

            const typeInfo = @typeInfo(T);

            // Early return to handle errors
            if (typeInfo == .ErrorUnion) {
                const value = coerceError(obj) catch |err| return err;
                return Trampoline(typeInfo.ErrorUnion.payload).wrap(value);
            }

            // Early return to handle optionals
            if (typeInfo == .Optional) {
                const value = obj orelse return py.None();
                return Trampoline(typeInfo.Optional.child).wrap(value);
            }

            // Shortcut for object types
            if (isObjectLike()) {
                const pyobj = asObject(obj);
                pyobj.incref();
                return pyobj;
            }

            switch (@typeInfo(T)) {
                .Bool => return if (obj) py.True().obj else py.False().obj,
                .ErrorUnion => @compileError("ErrorUnion already handled"),
                .Float => return (try py.PyFloat.create(obj)).obj,
                .Int => return (try py.PyLong.create(obj)).obj,
                .Pointer => |p| {
                    // We make the assumption that []const u8 is converted to a PyUnicode.
                    if (p.child == u8 and p.size == .Slice and p.is_const) {
                        return (try py.PyString.create(obj)).obj;
                    }

                    // Also pointers to u8 arrays *[_]u8
                    const childInfo = @typeInfo(p.child);
                    if (childInfo == .Array and childInfo.Array.child == u8) {
                        return (try py.PyString.create(obj)).obj;
                    }
                },
                .Struct => |s| {
                    // If the struct is a tuple, convert into a Python tuple
                    if (s.is_tuple) {
                        return (try py.PyTuple.create(obj)).obj;
                    }

                    // Otherwise, return a Python dictionary
                    return (try py.PyDict.create(obj)).obj;
                },
                .Void => return py.None(),
                else => {},
            }

            @compileError("Unsupported return type " ++ @typeName(T));
        }

        /// Unwrap a Python object into a Zig object. Does not steal a reference.
        /// The Python object must be the correct corresponding type (vs a cast which coerces values).
        pub inline fn unwrap(object: ?py.PyObject) PyError!T {
            // Handle the error case explicitly, then we can unwrap the error case entirely.
            const typeInfo = @typeInfo(T);

            // Early return to handle errors
            if (typeInfo == .ErrorUnion) {
                const value = coerceError(object) catch |err| return err;
                return @as(T, Trampoline(typeInfo.ErrorUnion.payload).unwrap(value));
            }

            // Early return to handle optionals
            if (typeInfo == .Optional) {
                const value = object orelse return null;
                if (py.is_none(value)) return null;
                return @as(T, try Trampoline(typeInfo.Optional.child).unwrap(value));
            }

            // Otherwise we can unwrap the object.
            var obj = object orelse @panic("Unexpected null");

            switch (@typeInfo(T)) {
                .Bool => return (try py.PyBool.checked(obj)).asbool(),
                .ErrorUnion => @compileError("ErrorUnion already handled"),
                .Float => return try (try py.PyFloat.checked(obj)).as(T),
                .Int => return try (try py.PyLong.checked(obj)).as(T),
                .Optional => @compileError("Optional already handled"),
                .Pointer => |p| {
                    if (State.findDefinition(p.child)) |def| {
                        // If the pointer is for a Pydust module
                        if (def.type == .module) {
                            const mod = try py.PyModule.checked(obj);
                            return try mod.getState(p.child);
                        }

                        // If the pointer is for a Pydust class
                        if (def.type == .class) {
                            // TODO(ngates): #193
                            const Cls = try py.self(p.child);
                            defer Cls.decref();

                            if (!try py.isinstance(obj, Cls)) {
                                const clsName = State.getIdentifier(p.child).name;
                                const mod = State.getContaining(p.child, .module);
                                const modName = State.getIdentifier(mod).name;
                                return py.TypeError.raiseFmt(
                                    "Expected {s}.{s} but found {s}",
                                    .{ modName, clsName, try obj.getTypeName() },
                                );
                            }

                            const PyType = pytypes.PyTypeStruct(p.child);
                            const pyobject = @as(*PyType, @ptrCast(obj.py));
                            return @constCast(&pyobject.state);
                        }
                    }

                    // We make the assumption that []const u8 is converted from a PyString
                    if (p.child == u8 and p.size == .Slice and p.is_const) {
                        return (try py.PyString.checked(obj)).asSlice();
                    }

                    @compileError("Unsupported pointer type " ++ @typeName(p.child));
                },
                .Struct => |s| {
                    // Support all extensions of py.PyObject, e.g. py.PyString, py.PyFloat
                    if (@hasField(T, "obj") and @hasField(std.meta.fieldInfo(T, .obj).type, "py")) {
                        return try @field(T, "checked")(obj);
                    }
                    // Support py.PyObject
                    if (T == py.PyObject and @TypeOf(obj) == py.PyObject) {
                        return obj;
                    }
                    // If the struct is a tuple, extract from the PyTuple
                    if (s.is_tuple) {
                        return (try py.PyTuple.checked(obj)).as(T);
                    }
                    // Otherwise, extract from a Python dictionary
                    return (try py.PyDict.checked(obj)).as(T);
                },
                .Void => if (py.is_none(obj)) return else return py.TypeError.raise("expected None"),
                else => {},
            }

            @compileError("Unsupported argument type " ++ @typeName(T));
        }

        // Unwrap the call args into a Pydust argument struct, borrowing references to the Python objects
        // but instantiating the args slice and kwargs map containers.
        // The caller is responsible for invoking deinit on the returned struct.
        pub inline fn unwrapCallArgs(pyargs: ?py.PyTuple, pykwargs: ?py.PyDict) PyError!ZigCallArgs {
            return ZigCallArgs.unwrap(pyargs, pykwargs);
        }

        const ZigCallArgs = struct {
            argsStruct: T,
            allPosArgs: []py.PyObject,

            pub fn unwrap(pyargs: ?py.PyTuple, pykwargs: ?py.PyDict) PyError!@This() {
                var kwargs = py.Kwargs.init(py.allocator);
                if (pykwargs) |kw| {
                    var iter = kw.itemsIterator();
                    while (iter.next()) |item| {
                        const key: []const u8 = try (try py.PyString.checked(item.k)).asSlice();
                        try kwargs.put(key, item.v);
                    }
                }

                const args = try py.allocator.alloc(py.PyObject, if (pyargs) |a| a.length() else 0);
                if (pyargs) |a| {
                    for (0..a.length()) |i| {
                        args[i] = try a.getItem(py.PyObject, i);
                    }
                }

                return .{ .argsStruct = try funcs.unwrapArgs(T, args, kwargs), .allPosArgs = args };
            }

            pub fn deinit(self: @This()) void {
                if (comptime funcs.varArgsIdx(T)) |idx| {
                    py.allocator.free(self.allPosArgs[0..idx]);
                } else {
                    py.allocator.free(self.allPosArgs);
                }

                inline for (@typeInfo(T).Struct.fields) |field| {
                    if (field.type == py.Args) {
                        py.allocator.free(@field(self.argsStruct, field.name));
                    }
                    if (field.type == py.Kwargs) {
                        var kwargs: py.Kwargs = @field(self.argsStruct, field.name);
                        kwargs.deinit();
                    }
                }
            }
        };
    };
}

/// Takes a value that optionally errors and coerces it always into a PyError.
pub fn coerceError(result: anytype) coerceErrorType(@TypeOf(result)) {
    const typeInfo = @typeInfo(@TypeOf(result));
    if (typeInfo == .ErrorUnion) {
        return result catch |err| {
            if (err == PyError.PyRaised) return PyError.PyRaised;
            if (err == PyError.OutOfMemory) return PyError.OutOfMemory;
            return py.RuntimeError.raise(@errorName(err));
        };
    } else {
        return result;
    }
}

fn coerceErrorType(comptime Result: type) type {
    const typeInfo = @typeInfo(Result);
    if (typeInfo == .ErrorUnion) {
        // Unwrap the error to ensure it's a PyError
        return PyError!typeInfo.ErrorUnion.payload;
    } else {
        // Always return a PyError union so the caller can always "try".
        return PyError!Result;
    }
}

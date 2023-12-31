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

const py = @import("./pydust.zig");
const tramp = @import("./trampoline.zig");
const pytypes = @import("./pytypes.zig");
const State = @import("./discovery.zig").State;

/// Zig PyObject-like -> ffi.PyObject. Convert a Zig PyObject-like value into a py.PyObject.
///  e.g. py.PyObject, py.PyTuple, ffi.PyObject, etc.
pub inline fn object(value: anytype) py.PyObject {
    return tramp.Trampoline(@TypeOf(value)).asObject(value);
}

/// Zig -> Python. Return a Python representation of a Zig object.
/// For Zig primitives, this constructs a new Python object.
/// For PyObject-like values, this returns the value without creating a new reference.
pub inline fn createOwned(value: anytype) py.PyError!py.PyObject {
    const trampoline = tramp.Trampoline(@TypeOf(value));
    defer trampoline.decref_objectlike(value);
    return trampoline.wrap(value);
}

/// Zig -> Python. Convert a Zig object into a Python object. Returns a new object.
pub inline fn create(value: anytype) py.PyError!py.PyObject {
    return tramp.Trampoline(@TypeOf(value)).wrap(value);
}

/// Python -> Zig. Return a Zig object representing the Python object.
pub inline fn as(comptime T: type, obj: anytype) py.PyError!T {
    return tramp.Trampoline(T).unwrap(object(obj));
}

/// Python -> Pydust. Perform a checked cast from a PyObject to a given PyDust class type.
pub inline fn checked(comptime T: type, obj: py.PyObject) py.PyError!T {
    const definition = State.getDefinition(@typeInfo(T).Pointer.child);
    if (definition.type != .class) {
        @compileError("Can only perform checked cast into a PyDust class type");
    }

    // TODO(ngates): to perform fast type checking, we need to store our PyType on the parent module.
    // See how the Python JSON module did this: https://github.com/python/cpython/commit/33f15a16d40cb8010a8c758952cbf88d7912ee2d#diff-efe183ae0b85e5b8d9bbbc588452dd4de80b39fd5c5174ee499ba554217a39edR1814
    // For now, we perform a slow import/isinstance check by using the `as` conversion.
    return as(T, obj);
}

/// Python -> Pydust. Perform an unchecked cast from a PyObject to a given PyDust class type.
pub inline fn unchecked(comptime T: type, obj: py.PyObject) T {
    const Definition = @typeInfo(T).Pointer.child;
    const definition = State.getDefinition(Definition);
    if (definition.type != .class) {
        @compileError("Can only perform unchecked cast into a PyDust class type. Found " ++ @typeName(Definition));
    }
    const instance: *pytypes.PyTypeStruct(Definition) = @ptrCast(@alignCast(obj.py));
    return &instance.state;
}

const testing = @import("std").testing;
const expect = testing.expect;

test "as py -> zig" {
    py.initialize();
    defer py.finalize();

    // Start with a Python object
    const str = try py.PyString.create("hello");
    try expect(py.refcnt(str) == 1);

    // Return a slice representation of it, and ensure the refcnt is untouched
    _ = try py.as([]const u8, str);
    try expect(py.refcnt(str) == 1);

    // Return a PyObject representation of it, and ensure the refcnt is untouched.
    _ = try py.as(py.PyObject, str);
    try expect(py.refcnt(str) == 1);
}

test "create" {
    py.initialize();
    defer py.finalize();

    const str = try py.PyString.create("Hello");
    try testing.expectEqual(@as(isize, 1), py.refcnt(str));

    const some_tuple = try py.create(.{str});
    defer some_tuple.decref();
    try testing.expectEqual(@as(isize, 2), py.refcnt(str));

    str.decref();
    try testing.expectEqual(@as(isize, 1), py.refcnt(str));
}

test "createOwned" {
    py.initialize();
    defer py.finalize();

    const str = try py.PyString.create("Hello");
    try testing.expectEqual(@as(isize, 1), py.refcnt(str));

    const some_tuple = try py.createOwned(.{str});
    defer some_tuple.decref();
    try testing.expectEqual(@as(isize, 1), py.refcnt(str));
}

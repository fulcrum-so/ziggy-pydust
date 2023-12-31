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

const std = @import("std");
const py = @import("../pydust.zig");
const PyObjectMixin = @import("./obj.zig").PyObjectMixin;

const ffi = py.ffi;

/// Wrapper for Python PyFrame.
/// See: https://docs.python.org/3/c-api/frame.html
pub const PyFrame = extern struct {
    obj: py.PyObject,

    pub fn get() ?PyFrame {
        const frame = ffi.PyEval_GetFrame();
        return if (frame) |f| .{ .obj = .{ .py = objPtr(f) } } else null;
    }

    pub fn code(self: PyFrame) py.PyCode {
        const codeObj = ffi.PyFrame_GetCode(framePtr(self.obj.py));
        return .{ .obj = .{ .py = @alignCast(@ptrCast(codeObj)) } };
    }

    pub inline fn lineNumber(self: PyFrame) u32 {
        return @intCast(ffi.PyFrame_GetLineNumber(framePtr(self.obj.py)));
    }

    inline fn framePtr(obj: *ffi.PyObject) *ffi.PyFrameObject {
        return @alignCast(@ptrCast(obj));
    }

    inline fn objPtr(obj: *ffi.PyFrameObject) *ffi.PyObject {
        return @alignCast(@ptrCast(obj));
    }
};

test "PyFrame" {
    py.initialize();
    defer py.finalize();

    const pf = PyFrame.get();
    try std.testing.expectEqual(@as(?PyFrame, null), pf);
}

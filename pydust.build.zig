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
const Step = std.Build.Step;
const LazyPath = std.Build.LazyPath;
const GeneratedFile = std.Build.GeneratedFile;

pub const PydustOptions = struct {};

pub const PythonModuleOptions = struct {
    name: [:0]const u8,
    // TODO(ngates): compute short name from full name
    short_name: [:0]const u8,
    root_source_file: std.Build.LazyPath,
    limited_api: bool = true,
    target: std.zig.CrossTarget,
    optimize: std.builtin.Mode,
    main_pkg_path: ?std.Build.LazyPath = null,
};

/// Configure a Pydust step
pub fn addPydust(b: *std.Build, options: PydustOptions) *PydustStep {
    return PydustStep.add(b, options);
}

pub const PydustStep = struct {
    step: Step,
    allocator: std.mem.Allocator,
    options: PydustOptions,

    pydust_source_file: GeneratedFile,
    python_include_dir: GeneratedFile,
    python_library_dir: GeneratedFile,

    pub fn add(b: *std.Build, options: PydustOptions) *PydustStep {
        var pydust = b.allocator.create(PydustStep) catch @panic("OOM");
        pydust.* = .{
            .step = Step.init(.{
                .id = .custom,
                .name = "configure pydust",
                .owner = b,
                .makeFn = make,
            }),
            .allocator = b.allocator,
            .options = options,
            .pydust_source_file = .{ .step = &pydust.step },
            .python_include_dir = .{ .step = &pydust.step },
            .python_library_dir = .{ .step = &pydust.step },
        };
        return pydust;
    }

    pub fn addPythonModule(self: *PydustStep, options: PythonModuleOptions) *std.build.CompileStep {
        const b = self.step.owner;

        const pyconf = b.addOptions();
        pyconf.addOption([:0]const u8, "module_name", options.name);
        pyconf.addOption(bool, "limited_api", options.limited_api);
        pyconf.addOption([:0]const u8, "hexversion", "0x030b05f0");

        // Configure and install the Python module shared library
        const lib = b.addSharedLibrary(.{
            .name = options.name,
            .root_source_file = options.root_source_file,
            .target = options.target,
            .optimize = options.optimize,
            .main_pkg_path = options.main_pkg_path,
        });
        lib.addOptions("pyconf", pyconf);
        lib.addAnonymousModule("pydust", .{
            .source_file = .{ .generated = &self.pydust_source_file },
            .dependencies = &.{.{ .name = "pyconf", .module = pyconf.createModule() }},
        });
        lib.addIncludePath(.{ .generated = &self.python_include_dir });
        lib.linkLibC();
        lib.linker_allow_shlib_undefined = true;

        // Install the shared library within the source tree
        const install = b.addInstallFileWithDir(
            lib.getEmittedBin(),
            // TODO(ngates): find this somehow?
            .{ .custom = ".." }, // Relative to project root: zig-out/../
            "example/exceptions.abi3.so",
        );
        b.getInstallStep().dependOn(&install.step);

        // Configure a test runner for the module
        const libtest = b.addTest(.{
            .root_source_file = .{ .path = "example/exceptions.zig" },
            .main_pkg_path = .{ .path = "example/" },
            .target = options.target,
            .optimize = options.optimize,
        });
        libtest.addOptions("pyconf", pyconf);
        libtest.addAnonymousModule("pydust", .{
            .source_file = .{ .generated = &self.pydust_source_file },
            .dependencies = &.{.{ .name = "pyconf", .module = pyconf.createModule() }},
        });
        libtest.addIncludePath(.{ .generated = &self.python_include_dir });
        libtest.linkLibC();
        libtest.linker_allow_shlib_undefined = true;
        libtest.linkSystemLibrary("python3.11");
        libtest.addLibraryPath(.{ .generated = &self.python_library_dir });

        // // Install the test binary
        // const install_libtest = b.addInstallBinFile(
        //     libtest.getEmittedBin(),
        //     "exceptions.test.bin",
        // );
        // test_build_step.dependOn(&installexceptions.step);
        // test_build_step.dependOn(&installtestexceptions.step);

        // // Run the tests as part of zig build test.
        // const run_testexceptions = b.addRunArtifact(testexceptions);
        // test_step.dependOn(&run_testexceptions.step);

        return lib;
    }

    /// During this step we discover the locations of the Python include and lib directories
    fn make(step: *Step, progress: *std.Progress.Node) !void {
        _ = progress;
        const self = @fieldParentPtr(PydustStep, "step", step);

        self.python_include_dir.path = try self.getPythonOutput(
            "import sysconfig; print(sysconfig.get_path('include'), end='')",
        );

        self.python_library_dir.path = try self.getPythonOutput(
            "import sysconfig; print(sysconfig.get_config_var('LIBDIR'), end='')",
        );

        self.pydust_source_file.path = try self.getPythonOutput(
            "import pydust; import os; print(os.path.join(os.path.dirname(pydust.__file__), 'src/pydust.zig'), end='')",
        );
    }

    fn getPythonOutput(self: *PydustStep, code: []const u8) ![]const u8 {
        const result = try std.process.Child.exec(.{
            .allocator = self.allocator,
            .argv = &.{ "python", "-c", code },
        });
        if (result.term.Exited != 0) {
            std.debug.print("Failed to execute {s}:\n{s}\n", .{ code, result.stderr });
            std.process.exit(1);
        }
        self.allocator.free(result.stderr);
        return result.stdout;
    }
};
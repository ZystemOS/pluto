const std = @import("std");
const builtin = @import("builtin");
const Builder = std.build.Builder;
const LibExeObjStep = std.build.LibExeObjStep;
const Step = std.build.Step;
const Target = std.build.Target;
const fs = std.fs;
const Mode = builtin.Mode;

pub fn build(b: *Builder) !void {
    const target = Target{
        .Cross = Target.Cross{
            .arch = .i386,
            .os = .freestanding,
            .abi = .gnu,
            .cpu_features = Target.CpuFeatures.initFromCpu(.i386, &builtin.Target.x86.cpu._i686),
        },
    };

    const test_target = Target{
        .Cross = Target.Cross{
            .arch = .i386,
            .os = .linux,
            .abi = .gnu,
            .cpu_features = Target.CpuFeatures.initFromCpu(.i386, &builtin.Target.x86.cpu._i686),
        },
    };

    const target_str = switch (target.getArch()) {
        .i386 => "x86",
        else => unreachable,
    };

    const fmt_step = b.addFmt(&[_][]const u8{
        "build.zig",
        "src",
        "test",
    });
    b.default_step.dependOn(&fmt_step.step);

    const main_src = "src/kernel/kmain.zig";
    const constants_path = try fs.path.join(b.allocator, &[_][]const u8{ "src/kernel/arch", target_str, "constants.zig" });

    const build_mode = b.standardReleaseOptions();
    const rt_test = b.option(bool, "rt-test", "enable/disable runtime testing") orelse false;

    const exec = b.addExecutable("pluto", main_src);
    exec.addPackagePath("constants", constants_path);
    exec.setOutputDir(b.cache_root);
    exec.addBuildOption(bool, "rt_test", rt_test);
    exec.setBuildMode(build_mode);
    exec.setLinkerScriptPath("link.ld");
    exec.setTheTarget(target);

    const output_iso = try fs.path.join(b.allocator, &[_][]const u8{ b.exe_dir, "pluto.iso" });
    const iso_dir_path = try fs.path.join(b.allocator, &[_][]const u8{ b.exe_dir, "iso" });
    const boot_path = try fs.path.join(b.allocator, &[_][]const u8{ b.exe_dir, "iso", "boot" });
    const modules_path = try fs.path.join(b.allocator, &[_][]const u8{ b.exe_dir, "iso", "modules" });

    const make_iso = b.addSystemCommand(&[_][]const u8{ "./makeiso.sh", boot_path, modules_path, iso_dir_path, exec.getOutputPath(), output_iso });

    make_iso.step.dependOn(&exec.step);
    b.default_step.dependOn(&make_iso.step);

    const test_step = b.step("test", "Run tests");
    if (rt_test) {
        const script = b.addSystemCommand(&[_][]const u8{ "python3", "test/rt-test.py", "x86", b.zig_exe });
        test_step.dependOn(&script.step);
    } else {
        const mock_path = "\"../../test/mock/kernel/\"";
        const arch_mock_path = "\"../../../../test/mock/kernel/\"";
        const unit_tests = b.addTest(main_src);
        unit_tests.setBuildMode(build_mode);
        unit_tests.setMainPkgPath(".");
        unit_tests.addPackagePath("constants", constants_path);
        unit_tests.addBuildOption(bool, "rt_test", rt_test);
        unit_tests.addBuildOption([]const u8, "mock_path", mock_path);
        unit_tests.addBuildOption([]const u8, "arch_mock_path", arch_mock_path);

        const qemu_bin = switch (test_target.getArch()) {
            .i386 => "qemu-i386",
            else => unreachable,
        };

        // We need this as the build as the make() doesn't handle it properly
        unit_tests.setExecCmd(&[_]?[]const u8{ qemu_bin, null });
        unit_tests.setTheTarget(test_target);

        test_step.dependOn(&unit_tests.step);
    }

    const run_step = b.step("run", "Run with qemu");
    const run_debug_step = b.step("debug-run", "Run with qemu and wait for a gdb connection");

    const qemu_bin = switch (target.getArch()) {
        .i386 => "qemu-system-i386",
        else => unreachable,
    };
    const qemu_args = &[_][]const u8{
        qemu_bin,
        "-cdrom",
        output_iso,
        "-boot",
        "d",
        "-serial",
        "stdio",
    };
    const qemu_cmd = b.addSystemCommand(qemu_args);
    const qemu_debug_cmd = b.addSystemCommand(qemu_args);
    qemu_debug_cmd.addArgs(&[_][]const u8{ "-s", "-S" });

    if (rt_test) {
        const qemu_rt_test_args = &[_][]const u8{ "-display", "none" };
        qemu_cmd.addArgs(qemu_rt_test_args);
        qemu_debug_cmd.addArgs(qemu_rt_test_args);
    }

    qemu_cmd.step.dependOn(&make_iso.step);
    qemu_debug_cmd.step.dependOn(&make_iso.step);

    run_step.dependOn(&qemu_cmd.step);
    run_debug_step.dependOn(&qemu_debug_cmd.step);

    const debug_step = b.step("debug", "Debug with gdb and connect to a running qemu instance");
    const symbol_file_arg = try std.mem.join(b.allocator, " ", &[_][]const u8{ "symbol-file", exec.getOutputPath() });
    const debug_cmd = b.addSystemCommand(&[_][]const u8{
        "gdb",
        "-ex",
        symbol_file_arg,
    });
    debug_cmd.addArgs(&[_][]const u8{
        "-ex",
        "target remote localhost:1234",
    });
    debug_step.dependOn(&debug_cmd.step);
}

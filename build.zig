const std = @import("std");
const builtin = @import("builtin");
const Builder = std.build.Builder;
const Step = std.build.Step;
const Target = std.build.Target;
const fs = std.fs;
const Mode = builtin.Mode;

pub fn build(b: *Builder) !void {
    const target = Target{
        .Cross = std.build.CrossTarget{
            .arch = .i386,
            .os = .freestanding,
            .abi = .gnu,
        },
    };

    const target_str = switch (target.getArch()) {
        builtin.Arch.i386 => "x86",
        else => unreachable,
    };
    const debug = b.option(bool, "debug", "build with debug symbols / make qemu wait for a debug connection") orelse false;
    const rt_test = b.option(bool, "rt-test", "enable/disable runtime testing") orelse false;

    const main_src = "src/kernel/kmain.zig";
    const exec = b.addExecutable("pluto", main_src);
    exec.setMainPkgPath(".");
    const const_path = try fs.path.join(b.allocator, [_][]const u8{ "src/kernel/arch/", target_str, "/constants.zig" });
    exec.addPackagePath("constants", const_path);
    exec.addBuildOption(bool, "rt_test", rt_test);
    exec.setLinkerScriptPath("link.ld");
    exec.setTheTarget(target);
    switch (target.getArch()) {
        .i386 => {
            exec.addAssemblyFile("src/kernel/arch/x86/irq_asm.s");
            exec.addAssemblyFile("src/kernel/arch/x86/isr_asm.s");
        },
        else => {},
    }

    const iso_path = fs.path.join(b.allocator, [_][]const u8{ b.exe_dir, "pluto.iso" }) catch unreachable;
    const grub_build_path = fs.path.join(b.allocator, [_][]const u8{ b.exe_dir, "iso", "boot" }) catch unreachable;
    const iso_dir_path = fs.path.join(b.allocator, [_][]const u8{ b.exe_dir, "iso" }) catch unreachable;

    const mkdir_cmd = b.addSystemCommand([_][]const u8{ "mkdir", "-p", fs.path.dirname(grub_build_path).? });

    const grub_cmd = b.addSystemCommand([_][]const u8{ "cp", "-r", "grub", grub_build_path });
    grub_cmd.step.dependOn(&mkdir_cmd.step);

    const cp_elf_cmd = b.addSystemCommand([_][]const u8{"cp"});
    cp_elf_cmd.addArtifactArg(exec);
    cp_elf_cmd.addArg(try fs.path.join(b.allocator, [_][]const u8{ grub_build_path, "pluto.elf" }));
    cp_elf_cmd.step.dependOn(&grub_cmd.step);
    cp_elf_cmd.step.dependOn(&exec.step);

    const iso_cmd = b.addSystemCommand([_][]const u8{ "grub-mkrescue", "-o", iso_path, iso_dir_path });
    iso_cmd.step.dependOn(&cp_elf_cmd.step);
    b.default_step.dependOn(&iso_cmd.step);

    const run_step = b.step("run", "Run with qemu");
    const qemu_bin = if (target.getArch() == builtin.Arch.i386) "qemu-system-i386" else unreachable;
    const qemu_cmd = b.addSystemCommand([_][]const u8{
        qemu_bin,
        "-cdrom",
        iso_path,
        "-boot",
        "d",
        "-serial",
        "stdio",
    });
    if (debug)
        qemu_cmd.addArgs([_][]const u8{ "-s", "-S" });
    if (rt_test)
        qemu_cmd.addArgs([_][]const u8{ "-display", "none" });
    run_step.dependOn(&qemu_cmd.step);
    qemu_cmd.step.dependOn(&iso_cmd.step);

    const test_step = b.step("test", "Run tests");
    if (rt_test) {
        const script = b.addSystemCommand([_][]const u8{ "python3", "test/rt-test.py", "x86", b.zig_exe });
        test_step.dependOn(&script.step);
    } else {
        inline for ([_]Mode{ Mode.Debug, Mode.ReleaseFast, Mode.ReleaseSafe, Mode.ReleaseSmall }) |test_mode| {
            const mode_str = comptime modeToString(test_mode);
            const unit_tests = b.addTest("test/unittests/test_all.zig");
            unit_tests.setBuildMode(test_mode);
            unit_tests.setMainPkgPath(".");
            unit_tests.setNamePrefix(mode_str ++ " - ");
            unit_tests.addPackagePath("mocking", "test/mock/kernel/mocking.zig");
            unit_tests.addPackagePath("constants", const_path);
            unit_tests.addBuildOption(bool, "rt_test", rt_test);
            test_step.dependOn(&unit_tests.step);
        }
    }

    const debug_step = b.step("debug", "Debug with gdb");
    const debug_cmd = b.addSystemCommand([_][]const u8{
        "gdb",
        "-ex",
        "symbol-file",
    });
    debug_cmd.addArtifactArg(exec);
    debug_cmd.addArgs([_][]const u8{
        "-ex",
        "target remote localhost:1234",
    });
    debug_step.dependOn(&debug_cmd.step);
}

fn modeToString(comptime mode: Mode) []const u8 {
    return switch (mode) {
        Mode.Debug => "debug",
        Mode.ReleaseFast => "release-fast",
        Mode.ReleaseSafe => "release-safe",
        Mode.ReleaseSmall => "release-small",
    };
}

// Zig version: 0.4.0

const Builder = @import("std").build.Builder;
const Step = @import("std").build.Step;
const builtin = @import("builtin");
const std = @import("std");
const os = std.os;
const ArrayList = std.ArrayList;
const warn = std.debug.warn;
const mem = std.mem;

var src_files: ArrayList([]const u8) = undefined;
var src_files_asm: ArrayList([]const u8) = undefined;

fn concat(allocator: *std.mem.Allocator, str: []const u8, str2: []const u8) !std.Buffer {
    var b = try std.Buffer.init(allocator, str);
    try b.append(str2);
    return b;
}

pub fn build(b: *Builder) void {
    src_files = ArrayList([]const u8).init(b.allocator);
    src_files_asm = ArrayList([]const u8).init(b.allocator);
    const debug = b.option(bool, "debug", "build with debug symbols / make qemu wait for a debug connection") orelse false;
    var build_path = b.option([]const u8, "build-path", "path to build to") orelse "bin";
    var src_path = b.option([]const u8, "source-path", "path to source") orelse "src";
    var target = b.option([]const u8, "target", "target to build/run for") orelse "x86";
    const rt_test = b.option(bool, "rt-test", "enable/disable runtime testing") orelse false;
    const builtin_target = if (mem.eql(u8, target, "x86")) builtin.Arch.i386 else unreachable;
    const zig_path = b.option([]const u8, "zig-path", "the path to the zig binary to use for rt testing") orelse "/snap/bin/zig";

    b.makePath(build_path) catch unreachable;
    var grub_path = concat(b.allocator, build_path, "/iso/boot/grub") catch unreachable;
    var kern_path = concat(b.allocator, build_path, "/kernel") catch unreachable;
    var a_path = concat(b.allocator, build_path, "/kernel/arch/") catch unreachable;
    a_path = concat(b.allocator, a_path.toSlice(), target) catch unreachable;
    b.makePath(grub_path.toSlice()) catch unreachable;
    b.makePath(kern_path.toSlice()) catch unreachable;
    b.makePath(a_path.toSlice()) catch unreachable;
    b.makePath("zig-cache/kernel") catch unreachable;

    src_files.append("kernel/kmain") catch unreachable;

    // Add the assemblies
    switch (builtin_target) {
        builtin.Arch.i386 => {
            src_files_asm.append("kernel/arch/x86/irq_asm") catch unreachable;
            src_files_asm.append("kernel/arch/x86/isr_asm") catch unreachable;
        },
        else => {},
    }

    var arch_boot = concat(b.allocator, "kernel/arch/", target) catch unreachable;
    arch_boot.append("/boot") catch unreachable;
    src_files.append(arch_boot.toSlice()) catch unreachable;

    const iso_path = concat(b.allocator, build_path, "/pluto.iso") catch unreachable;
    var objects = buildObjects(b, builtin_target, build_path, src_path);
    var link_step = buildLink(b, builtin_target, build_path);
    const iso_step = buildISO(b, build_path, iso_path.toSlice());

    for (objects.toSlice()) |obj| {
        if (std.mem.eql(u8, obj.name, "kernel/kmain")) {
            // Add build options here
            obj.addBuildOption(bool, "rt_test", rt_test);
        }
        b.default_step.dependOn(&obj.step);
    }
    b.default_step.dependOn(link_step);
    for (iso_step.toSlice()) |step| b.default_step.dependOn(step);

    buildRun(b, builtin_target, build_path, iso_path.toSlice(), debug, rt_test);
    buildDebug(b);
    buildTest(b, src_path, rt_test, target, zig_path);
}

fn buildTest(b: *Builder, src_path: []const u8, rt_test: bool, target: []const u8, zig_path: []const u8) void {
    const step = b.step("test", "Run tests");
    if (rt_test) {
        const script = b.addSystemCommand([][]const u8{ "python3", "test/rt-test.py", target, zig_path});
        step.dependOn(&script.step);
    } else {
        const src_path2 = concat(b.allocator, src_path, "/") catch unreachable;
        for (src_files.toSlice()) |file| {
            var file_src = concat(b.allocator, src_path2.toSlice(), file) catch unreachable;
            file_src.append(".zig") catch unreachable;
            const tst = b.addTest(file_src.toSlice());
            tst.setMainPkgPath(".");
            step.dependOn(&tst.step);
        }
    }
}

fn buildDebug(b: *Builder) void {
    const step = b.step("debug", "Debug with gdb");
    const cmd = b.addSystemCommand([][]const u8{
        "gdb",
        "-ex",
        "symbol-file bin/iso/boot/pluto.elf",
        "-ex",
        "target remote localhost:1234",
    });
    step.dependOn(&cmd.step);
}

fn buildRun(b: *Builder, target: builtin.Arch, build_path: []const u8, iso_path: []const u8, debug: bool, rt_test: bool) void {
    const step = b.step("run", "Run with qemu");
    const qemu = if (target == builtin.Arch.i386) "qemu-system-i386" else unreachable;
    var qemu_flags = ArrayList([]const u8).init(b.allocator);
    qemu_flags.appendSlice([][]const u8{
        qemu,
        "-cdrom",
        iso_path,
        "-boot",
        "d",
        "-serial",
        "stdio",
    }) catch unreachable;
    if (debug)
        qemu_flags.appendSlice([][]const u8{
            "-s",
            "-S",
        }) catch unreachable;
    if (rt_test)
        qemu_flags.appendSlice([][]const u8{
            "-display",
            "none"
        }) catch unreachable;
    const cmd = b.addSystemCommand(qemu_flags.toSlice());
    step.dependOn(&cmd.step);
}

fn buildISO(b: *Builder, build_path: []const u8, iso_path: []const u8) ArrayList(*Step) {
    const grub_build_path = concat(b.allocator, build_path, "/iso/boot/") catch unreachable;
    const iso_dir_path = concat(b.allocator, build_path, "/iso") catch unreachable;
    const grub_cmd = b.addSystemCommand([][]const u8{ "cp", "-r", "grub", grub_build_path.toSlice() });
    const iso_cmd = b.addSystemCommand([][]const u8{ "grub-mkrescue", "-o", iso_path, iso_dir_path.toSlice() });
    var steps = ArrayList(*Step).init(b.allocator);
    steps.append(&grub_cmd.step) catch unreachable;
    steps.append(&iso_cmd.step) catch unreachable;
    return steps;
}

fn buildLink(b: *Builder, target: builtin.Arch, build_path: []const u8) *Step {
    const exec = b.addExecutable("pluto.elf", null);
    const elf_path = concat(b.allocator, build_path, "/iso/boot") catch unreachable;
    exec.setOutputDir(elf_path.toSlice());
    exec.setLinkerScriptPath("link.ld");
    exec.setTarget(target, builtin.Os.freestanding, builtin.Abi.gnu);
    for (src_files.toSlice()) |file| {
        var file_obj = concat(b.allocator, build_path, "/") catch unreachable;
        file_obj.append(file) catch unreachable;
        file_obj.append(".o") catch unreachable;
        exec.addObjectFile(file_obj.toSlice());
        exec.setMainPkgPath(".");
    }
    for (src_files_asm.toSlice()) |file| {
        var file_obj = concat(b.allocator, build_path, "/") catch unreachable;
        file_obj.append(file) catch unreachable;
        file_obj.append(".o") catch unreachable;
        exec.addObjectFile(file_obj.toSlice());
    }
    return &exec.step;
}

fn buildObjects(b: *Builder, target: builtin.Arch, build_path: []const u8, src_path: []const u8) ArrayList(*std.build.LibExeObjStep) {
    var objects = ArrayList(*std.build.LibExeObjStep).init(b.allocator);
    const src_path2 = concat(b.allocator, src_path, "/") catch unreachable;
    for (src_files.toSlice()) |file| {
        var file_src = concat(b.allocator, src_path2.toSlice(), file) catch unreachable;
        file_src.append(".zig") catch unreachable;
        const obj = b.addObject(file, file_src.toSlice());
        obj.setMainPkgPath(".");
        obj.setOutputDir(build_path);
        obj.setTarget(target, builtin.Os.freestanding, builtin.Abi.gnu);
        objects.append(obj) catch unreachable;
    }
    for (src_files_asm.toSlice()) |file| {
        var file_src = concat(b.allocator, src_path2.toSlice(), file) catch unreachable;
        file_src.append(".s") catch unreachable;
        const obj = b.addAssemble(file, file_src.toSlice());
        obj.setOutputDir(build_path);
        obj.setTarget(target, builtin.Os.freestanding, builtin.Abi.gnu);
        objects.append(obj) catch unreachable;
    }
    return objects;
}

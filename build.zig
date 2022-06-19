const std = @import("std");
const log = std.log.scoped(.builder);
const builtin = @import("builtin");
const rt = @import("test/runtime_test.zig");
const RuntimeStep = rt.RuntimeStep;
const Allocator = std.mem.Allocator;
const Builder = std.build.Builder;
const Step = std.build.Step;
const Target = std.Target;
const CrossTarget = std.zig.CrossTarget;
const fs = std.fs;
const File = fs.File;
const Mode = std.builtin.Mode;
const TestMode = rt.TestMode;
const ArrayList = std.ArrayList;
const Pkg = std.build.Pkg;
const Fat32 = @import("mkfat32.zig").Fat32;

const x86_i686 = CrossTarget{
    .cpu_arch = .i386,
    .os_tag = .freestanding,
    .cpu_model = .{ .explicit = &Target.x86.cpu._i686 },
};

const aarch64_cortexa53 = CrossTarget{
    .cpu_arch = .aarch64,
    .os_tag = .freestanding,
    .cpu_model = .{ .explicit = &Target.aarch64.cpu.cortex_a53 },
};

pub fn build(b: *Builder) !void {
    const target = b.standardTargetOptions(.{ .whitelist = &[_]CrossTarget{ x86_i686, aarch64_cortexa53 }, .default_target = x86_i686 });
    const arch = switch (target.getCpuArch()) {
        .i386 => "x86",
        .aarch64 => "aarch64",
        else => unreachable,
    };

    const fmt_step = b.addFmt(&[_][]const u8{
        "build.zig",
        "mkfat32.zig",
        "src",
        "test",
    });
    b.default_step.dependOn(&fmt_step.step);

    const main_src = "src/kernel/kmain.zig";
    const pluto_src = "src/kernel/pluto.zig";
    const arch_root = "src/kernel/arch";
    const arch_mock_src = "test/mock/kernel/arch_mock.zig";
    const elf_name = "pluto.elf";
    const arch_src = try fs.path.join(b.allocator, &[_][]const u8{ arch_root, arch, "arch.zig" });
    const linker_script_path = try fs.path.join(b.allocator, &[_][]const u8{ arch_root, arch, "link.ld" });
    const output_iso = try fs.path.join(b.allocator, &[_][]const u8{ b.install_path, "pluto.iso" });
    const output_elf = try fs.path.join(b.allocator, &[_][]const u8{ b.install_path, elf_name });
    const iso_dir_path = try fs.path.join(b.allocator, &[_][]const u8{ b.install_path, "iso" });
    const boot_path = try fs.path.join(b.allocator, &[_][]const u8{ b.install_path, "iso", "boot" });
    const modules_path = try fs.path.join(b.allocator, &[_][]const u8{ b.install_path, "iso", "modules" });
    const ramdisk_path = try fs.path.join(b.allocator, &[_][]const u8{ b.install_path, "initrd.ramdisk" });
    const fat32_image_path = try fs.path.join(b.allocator, &[_][]const u8{ b.install_path, "fat32.img" });
    const test_fat32_image_path = try fs.path.join(b.allocator, &[_][]const u8{ "test", "fat32", "test_fat32.img" });

    const build_mode = b.standardReleaseOptions();
    comptime var test_mode_desc: []const u8 = "\n                         ";
    inline for (@typeInfo(TestMode).Enum.fields) |field| {
        const tm = @field(TestMode, field.name);
        test_mode_desc = test_mode_desc ++ field.name ++ " (" ++ TestMode.getDescription(tm) ++ ")";
        test_mode_desc = test_mode_desc ++ "\n                         ";
    }

    const test_mode = b.option(TestMode, "test-mode", "Run a specific runtime test. This option is for the rt-test step. Available options: " ++ test_mode_desc) orelse .None;
    const disable_display = b.option(bool, "disable-display", "Disable the qemu window") orelse false;

    const exec = b.addExecutable(elf_name, main_src);
    const exec_output_path = try fs.path.join(b.allocator, &[_][]const u8{ b.install_path, "pluto.elf" });
    exec.setOutputDir(b.install_path);
    const exec_options = b.addOptions();
    exec.addOptions("build_options", exec_options);
    exec_options.addOption(TestMode, "test_mode", test_mode);
    exec.setBuildMode(build_mode);
    exec.setLinkerScriptPath(std.build.FileSource{ .path = linker_script_path });
    exec.setTarget(target);

    var pluto_pkg = Pkg{ .name = "pluto", .path = .{ .path = pluto_src } };
    var arch_pkg = Pkg{ .name = "arch", .path = .{ .path = arch_src } };
    var arch_mock_pkg = Pkg{ .name = "arch_mock", .path = .{ .path = arch_mock_src } };
    arch_mock_pkg.dependencies = &[_]Pkg{ arch_pkg, pluto_pkg, exec_options.getPackage("build_options") };
    pluto_pkg.dependencies = &[_]Pkg{ arch_pkg, arch_mock_pkg, exec_options.getPackage("build_options") };
    arch_pkg.dependencies = &[_]Pkg{ pluto_pkg, arch_mock_pkg, exec_options.getPackage("build_options") };
    exec.addPackage(pluto_pkg);
    exec.addPackage(arch_pkg);
    exec.addPackage(arch_mock_pkg);

    const make_iso = switch (target.getCpuArch()) {
        .i386 => b.addSystemCommand(&[_][]const u8{ "./makeiso.sh", boot_path, modules_path, iso_dir_path, output_elf, ramdisk_path, output_iso }),
        .aarch64 => makeRpiImage: {
            const elf = try fs.path.join(b.allocator, &[_][]const u8{ exec.output_dir.?, "pluto.elf" });
            _ = elf;
            const kernel_image = "kernel8.img";
            const sdcard_image = try fs.path.join(b.allocator, &[_][]const u8{ b.cache_root, "rpi-sdcard.img" });

            const install_raw = b.addInstallBinFile(exec.getOutputSource(), kernel_image);
            install_raw.step.dependOn(&exec.step);

            const allocate_sdcard_image = b.addSystemCommand(&[_][]const u8{
                "fallocate",
                "-l",
                "64M",
                sdcard_image,
            });
            allocate_sdcard_image.step.dependOn(&install_raw.step);

            const format_sdcard_image = b.addSystemCommand(&[_][]const u8{
                "mformat",
                "-i",
                sdcard_image,
                "-F",
            });
            format_sdcard_image.step.dependOn(&allocate_sdcard_image.step);

            const copy_bootcode = b.addSystemCommand(&[_][]const u8{
                "mcopy",
                "-i",
                sdcard_image,
                "src/kernel/arch/aarch64/rpi-sdcard/bootcode.bin",
                "::bootcode.bin",
            });
            copy_bootcode.step.dependOn(&format_sdcard_image.step);

            const copy_config = b.addSystemCommand(&[_][]const u8{
                "mcopy",
                "-i",
                sdcard_image,
                "src/kernel/arch/aarch64/rpi-sdcard/config.txt",
                "::config.txt",
            });
            copy_config.step.dependOn(&copy_bootcode.step);

            const copy_fixup = b.addSystemCommand(&[_][]const u8{
                "mcopy",
                "-i",
                sdcard_image,
                "src/kernel/arch/aarch64/rpi-sdcard/fixup.dat",
                "::fixup.dat",
            });
            copy_fixup.step.dependOn(&copy_config.step);

            const copy_kernel = b.addSystemCommand(&[_][]const u8{
                "mcopy",
                "-i",
                sdcard_image,
                b.getInstallPath(.bin, kernel_image),
                "::kernel8.img",
            });
            copy_kernel.step.dependOn(&copy_fixup.step);

            const copy_start = b.addSystemCommand(&[_][]const u8{
                "mcopy",
                "-i",
                sdcard_image,
                "src/kernel/arch/aarch64/rpi-sdcard/start.elf",
                "::start.elf",
            });
            copy_start.step.dependOn(&copy_kernel.step);

            break :makeRpiImage copy_start;
        },
        else => unreachable,
    };
    make_iso.step.dependOn(&exec.step);

    var fat32_builder_step = Fat32BuilderStep.create(b, .{}, fat32_image_path);
    make_iso.step.dependOn(&fat32_builder_step.step);

    var ramdisk_files_al = ArrayList([]const u8).init(b.allocator);
    defer ramdisk_files_al.deinit();

    if (test_mode == .Initialisation) {
        // Add some test files for the ramdisk runtime tests
        try ramdisk_files_al.append("test/ramdisk_test1.txt");
        try ramdisk_files_al.append("test/ramdisk_test2.txt");
    } else if (test_mode == .Scheduler) {
        inline for (&[_][]const u8{ "user_program_data", "user_program" }) |user_program| {
            // Add some test files for the user mode runtime tests
            const user_program_step = b.addExecutable(user_program ++ ".elf", null);
            user_program_step.setLinkerScriptPath(.{ .path = "test/user_program.ld" });
            user_program_step.addAssemblyFile("test/" ++ user_program ++ ".s");
            user_program_step.setOutputDir(b.install_path);
            user_program_step.setTarget(target);
            user_program_step.setBuildMode(build_mode);
            user_program_step.strip = true;
            exec.step.dependOn(&user_program_step.step);
            const user_program_path = try std.mem.join(b.allocator, "/", &[_][]const u8{ b.install_path, user_program ++ ".elf" });
            try ramdisk_files_al.append(user_program_path);
        }
    }

    const ramdisk_step = RamdiskStep.create(b, target, ramdisk_files_al.toOwnedSlice(), ramdisk_path);
    make_iso.step.dependOn(&ramdisk_step.step);

    b.default_step.dependOn(&make_iso.step);

    const test_step = b.step("test", "Run tests");
    const unit_tests = b.addTest(main_src);
    unit_tests.setBuildMode(build_mode);
    unit_tests.setMainPkgPath(".");
    const unit_test_options = b.addOptions();
    unit_tests.addOptions("build_options", unit_test_options);
    unit_test_options.addOption(TestMode, "test_mode", test_mode);
    unit_tests.setTarget(.{ .cpu_arch = target.cpu_arch });
    unit_tests.addPackage(pluto_pkg);
    unit_tests.addPackage(arch_pkg);
    unit_tests.addPackage(arch_mock_pkg);

    if (builtin.os.tag != .windows) {
        b.enable_qemu = true;
    }

    // Run the mock gen
    const mock_gen = b.addExecutable("mock_gen", "test/gen_types.zig");
    mock_gen.setMainPkgPath(".");
    const mock_gen_run = mock_gen.run();
    unit_tests.step.dependOn(&mock_gen_run.step);
    exec.step.dependOn(&mock_gen_run.step);
    b.default_step.dependOn(&mock_gen_run.step);

    // Create test FAT32 image
    const test_fat32_img_step = Fat32BuilderStep.create(b, .{}, test_fat32_image_path);
    const copy_test_files_step = b.addSystemCommand(&[_][]const u8{ "./fat32_cp.sh", test_fat32_image_path });
    copy_test_files_step.step.dependOn(&test_fat32_img_step.step);
    unit_tests.step.dependOn(&copy_test_files_step.step);

    test_step.dependOn(&unit_tests.step);

    const rt_test_step = b.step("rt-test", "Run runtime tests");
    var qemu_args_al = ArrayList([]const u8).init(b.allocator);
    defer qemu_args_al.deinit();

    switch (target.getCpuArch()) {
        .i386 => try qemu_args_al.append("qemu-system-i386"),
        .aarch64 => try qemu_args_al.append("qemu-system-aarch64"),
        else => unreachable,
    }
    try qemu_args_al.append("-serial");
    try qemu_args_al.append("stdio");
    switch (target.getCpuArch()) {
        .i386 => {
            try qemu_args_al.append("-boot");
            try qemu_args_al.append("d");
            try qemu_args_al.append("-cdrom");
            try qemu_args_al.append(output_iso);
        },
        .aarch64 => try qemu_args_al.appendSlice(&[_][]const u8{ "-kernel", exec.output_dir.?, "-machine", "raspi3" }),
        else => unreachable,
    }
    if (disable_display) {
        try qemu_args_al.append("-display");
        try qemu_args_al.append("none");
    }

    var qemu_args = qemu_args_al.toOwnedSlice();

    const rt_step = RuntimeStep.create(b, test_mode, qemu_args);
    rt_step.step.dependOn(&make_iso.step);
    rt_test_step.dependOn(&rt_step.step);

    const run_step = b.step("run", "Run with qemu");
    const run_debug_step = b.step("debug-run", "Run with qemu and wait for a gdb connection");

    const qemu_cmd = b.addSystemCommand(qemu_args);
    const qemu_debug_cmd = b.addSystemCommand(qemu_args);
    qemu_debug_cmd.addArgs(&[_][]const u8{ "-s", "-S" });

    qemu_cmd.step.dependOn(&make_iso.step);
    qemu_debug_cmd.step.dependOn(&make_iso.step);

    run_step.dependOn(&qemu_cmd.step);
    run_debug_step.dependOn(&qemu_debug_cmd.step);

    const debug_step = b.step("debug", "Debug with gdb and connect to a running qemu instance");
    const symbol_file_arg = try std.mem.join(b.allocator, " ", &[_][]const u8{ "symbol-file", exec_output_path });
    const debug_cmd = b.addSystemCommand(&[_][]const u8{
        "gdb-multiarch",
        "-ex",
        symbol_file_arg,
        "-ex",
        "set architecture auto",
    });
    debug_cmd.addArgs(&[_][]const u8{
        "-ex",
        "target remote localhost:1234",
    });
    debug_step.dependOn(&debug_cmd.step);
}

/// The FAT32 step for creating a FAT32 image.
const Fat32BuilderStep = struct {
    /// The Step, that is all you need to know
    step: Step,

    /// The builder pointer, also all you need to know
    builder: *Builder,

    /// The path to where the ramdisk will be written to.
    out_file_path: []const u8,

    /// Options for creating the FAT32 image.
    options: Fat32.Options,

    ///
    /// The make function that is called by the builder.
    ///
    /// Arguments:
    ///     IN step: *Step - The step of this step.
    ///
    /// Error: error{EndOfStream} || File.OpenError || File.ReadError || File.WriteError || File.SeekError || Allocator.Error || Fat32.Error || Error
    ///     error{EndOfStream} || File.OpenError || File.ReadError || File.WriteError || File.SeekError - Error related to file operations. See std.fs.File.
    ///     Allocator.Error - If there isn't enough memory to allocate for the make step.
    ///     Fat32.Error     - If there was an error creating the FAT image. This will be invalid options.
    ///
    fn make(step: *Step) (error{EndOfStream} || File.OpenError || File.ReadError || File.WriteError || File.SeekError || Fat32.Error)!void {
        const self = @fieldParentPtr(Fat32BuilderStep, "step", step);
        // Open the out file
        const image = try std.fs.cwd().createFile(self.out_file_path, .{ .read = true });

        // If there was an error, delete the image as this will be invalid
        errdefer (std.fs.cwd().deleteFile(self.out_file_path) catch unreachable);
        defer image.close();
        try Fat32.make(self.options, image, false);
    }

    ///
    /// Create a FAT32 builder step.
    ///
    /// Argument:
    ///     IN builder: *Builder               - The build builder.
    ///     IN options: Options                - Options for creating FAT32 image.
    ///
    /// Return: *Fat32BuilderStep
    ///     The FAT32 builder step pointer to add to the build process.
    ///
    pub fn create(builder: *Builder, options: Fat32.Options, out_file_path: []const u8) *Fat32BuilderStep {
        const fat32_builder_step = builder.allocator.create(Fat32BuilderStep) catch unreachable;
        fat32_builder_step.* = .{
            .step = Step.init(.custom, builder.fmt("Fat32BuilderStep", .{}), builder.allocator, make),
            .builder = builder,
            .options = options,
            .out_file_path = out_file_path,
        };
        return fat32_builder_step;
    }
};

/// The ramdisk make step for creating the initial ramdisk.
const RamdiskStep = struct {
    /// The Step, that is all you need to know
    step: Step,

    /// The builder pointer, also all you need to know
    builder: *Builder,

    /// The target for the build
    target: CrossTarget,

    /// The list of files to be added to the ramdisk
    files: []const []const u8,

    /// The path to where the ramdisk will be written to.
    out_file_path: []const u8,

    /// The possible errors for creating a ramdisk
    const Error = (error{EndOfStream} || File.ReadError || File.SeekError || Allocator.Error || File.WriteError || File.OpenError);

    ///
    /// Create and write the files to a raw ramdisk in the format:
    /// (NumOfFiles:usize)[(name_length:usize)(name:u8[name_length])(content_length:usize)(content:u8[content_length])]*
    ///
    /// Argument:
    ///     IN comptime Usize: type - The usize type for the architecture.
    ///     IN self: *RamdiskStep   - Self.
    ///
    /// Error: Error
    ///     Errors for opening, reading and writing to and from files and for allocating memory.
    ///
    fn writeRamdisk(comptime Usize: type, self: *RamdiskStep) Error!void {
        // 1GB, don't think the ram disk should be very big
        const max_file_size = 1024 * 1024 * 1024;

        // Open the out file
        var ramdisk = try fs.cwd().createFile(self.out_file_path, .{});
        defer ramdisk.close();

        // Get the targets endian
        const endian = self.target.getCpuArch().endian();

        // First write the number of files/headers
        std.debug.assert(self.files.len < std.math.maxInt(Usize));
        try ramdisk.writer().writeInt(Usize, @truncate(Usize, self.files.len), endian);
        var current_offset: usize = 0;
        for (self.files) |file_path| {
            // Open, and read the file. Can get the size from this as well
            const file_content = try fs.cwd().readFileAlloc(self.builder.allocator, file_path, max_file_size);

            // Get the last occurrence of / for the file name, if there isn't one, then the file_path is the name
            const file_name_index = if (std.mem.lastIndexOf(u8, file_path, "/")) |index| index + 1 else 0;

            // Write the header and file content to the ramdisk
            // Name length
            std.debug.assert(file_path[file_name_index..].len < std.math.maxInt(Usize));
            try ramdisk.writer().writeInt(Usize, @truncate(Usize, file_path[file_name_index..].len), endian);

            // Name
            try ramdisk.writer().writeAll(file_path[file_name_index..]);

            // Length
            std.debug.assert(file_content.len < std.math.maxInt(Usize));
            try ramdisk.writer().writeInt(Usize, @truncate(Usize, file_content.len), endian);

            // File contest
            try ramdisk.writer().writeAll(file_content);

            // Increment the offset to the new location
            current_offset += @sizeOf(Usize) * 3 + file_path[file_name_index..].len + file_content.len;
        }
    }

    ///
    /// The make function that is called by the builder. This will switch on the target to get the
    /// correct usize length for the target.
    ///
    /// Arguments:
    ///     IN step: *Step - The step of this step.
    ///
    /// Error: Error
    ///     Errors for opening, reading and writing to and from files and for allocating memory.
    ///
    fn make(step: *Step) Error!void {
        const self = @fieldParentPtr(RamdiskStep, "step", step);
        switch (self.target.getCpuArch()) {
            .i386 => try writeRamdisk(u32, self),
            .aarch64 => try writeRamdisk(u64, self),
            else => unreachable,
        }
    }

    ///
    /// Create a ramdisk step.
    ///
    /// Argument:
    ///     IN builder: *Builder         - The build builder.
    ///     IN target: CrossTarget       - The target for the build.
    ///     IN files: []const []const u8 - The file names to be added to the ramdisk.
    ///     IN out_file_path: []const u8 - The output file path.
    ///
    /// Return: *RamdiskStep
    ///     The ramdisk step pointer to add to the build process.
    ///
    pub fn create(builder: *Builder, target: CrossTarget, files: []const []const u8, out_file_path: []const u8) *RamdiskStep {
        const ramdisk_step = builder.allocator.create(RamdiskStep) catch unreachable;
        ramdisk_step.* = .{
            .step = Step.init(.custom, builder.fmt("Ramdisk", .{}), builder.allocator, make),
            .builder = builder,
            .target = target,
            .files = files,
            .out_file_path = out_file_path,
        };
        return ramdisk_step;
    }
};

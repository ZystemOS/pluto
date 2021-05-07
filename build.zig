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
const Mode = builtin.Mode;
const TestMode = rt.TestMode;
const ArrayList = std.ArrayList;
const makefs = @import("src/kernel/filesystem/makefs.zig");

const fat32_driver = @import("src/kernel/filesystem/fat32.zig");
const mbr_driver = @import("src/kernel/filesystem/mbr.zig");

const FromTo = struct { from: []const u8, to: []const u8 };

const x86_i686 = CrossTarget{
    .cpu_arch = .i386,
    .os_tag = .freestanding,
    .cpu_model = .{ .explicit = &Target.x86.cpu._i686 },
};

const x86_64 = brk: {
    var tmp = CrossTarget{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
    };
    var disabled_features = std.Target.Cpu.Feature.Set.empty;
    var enabled_features = std.Target.Cpu.Feature.Set.empty;

    const features = std.Target.x86.Feature;
    // Disable SIMD registers
    disabled_features.addFeature(@enumToInt(features.mmx));
    disabled_features.addFeature(@enumToInt(features.sse));
    disabled_features.addFeature(@enumToInt(features.sse2));
    disabled_features.addFeature(@enumToInt(features.avx));
    disabled_features.addFeature(@enumToInt(features.avx2));

    enabled_features.addFeature(@enumToInt(features.soft_float));

    tmp.cpu_features_sub = disabled_features;
    tmp.cpu_features_add = enabled_features;
    break :brk tmp;
};

pub fn build(b: *Builder) !void {
    const target = b.standardTargetOptions(.{ .whitelist = &[_]CrossTarget{ x86_i686, x86_64 }, .default_target = x86_64 });
    const arch = switch (target.getCpuArch()) {
        .i386 => "x86/32bit",
        .x86_64 => "x86/64bit",
        else => unreachable,
    };

    const fmt_step = b.addFmt(&[_][]const u8{
        "build.zig",
        "src",
        "test",
    });
    b.default_step.dependOn(&fmt_step.step);

    const main_src = switch (target.getCpuArch()) {
        .i386 => "src/kernel/kmain.zig",
        .x86_64 => "src/kernel/kmain_64.zig",
        else => unreachable,
    };
    const arch_root = "src/kernel/arch";
    const linker_script_path = try fs.path.join(b.allocator, &[_][]const u8{ arch_root, arch, "link.ld" });
    const output_iso = try fs.path.join(b.allocator, &[_][]const u8{ b.exe_dir, "pluto.iso" });
    const iso_dir_path = try fs.path.join(b.allocator, &[_][]const u8{ b.exe_dir, "iso" });
    const boot_path = try fs.path.join(b.allocator, &[_][]const u8{ b.exe_dir, "iso", "boot" });
    const modules_path = try fs.path.join(b.allocator, &[_][]const u8{ b.exe_dir, "iso", "modules" });
    const ramdisk_path = try fs.path.join(b.allocator, &[_][]const u8{ b.install_path, "initrd.ramdisk" });
    const test_fat32_image_path = try fs.path.join(b.allocator, &[_][]const u8{ "test", "fat32", "test_fat32.img" });
    const boot_drive_image_path = try fs.path.join(b.allocator, &[_][]const u8{ b.install_path, "boot_drive.img" });
    const kernel_map_path = try fs.path.join(b.allocator, &[_][]const u8{ b.install_path, "kernel.map" });

    const build_mode = b.standardReleaseOptions();
    comptime var test_mode_desc: []const u8 = "\n                         ";
    inline for (@typeInfo(TestMode).Enum.fields) |field| {
        const tm = @field(TestMode, field.name);
        test_mode_desc = test_mode_desc ++ field.name ++ " (" ++ TestMode.getDescription(tm) ++ ")";
        test_mode_desc = test_mode_desc ++ "\n                         ";
    }

    const test_mode = b.option(TestMode, "test-mode", "Run a specific runtime test. This option is for the rt-test step. Available options: " ++ test_mode_desc) orelse .None;
    const disable_display = b.option(bool, "disable-display", "Disable the qemu window") orelse false;

    const exec = b.addExecutable("pluto.elf", main_src);
    exec.setOutputDir(b.install_path);
    exec.addBuildOption(TestMode, "test_mode", test_mode);
    exec.setBuildMode(build_mode);
    exec.setLinkerScriptPath(linker_script_path);
    exec.setTarget(target);
    exec.code_model = .kernel;

    const make_iso = switch (target.getCpuArch()) {
        .i386 => b.addSystemCommand(&[_][]const u8{ "./makeiso.sh", boot_path, modules_path, iso_dir_path, exec.getOutputPath(), ramdisk_path, output_iso }),
        .x86_64 => b.addSystemCommand(&[_][]const u8{ "./makeiso_64.sh", kernel_map_path, exec.getOutputPath(), output_iso, ramdisk_path }),
        else => unreachable,
    };
    make_iso.step.dependOn(&exec.step);

    // Make the init ram disk
    var ramdisk_files_al = ArrayList([]const u8).init(b.allocator);
    defer ramdisk_files_al.deinit();

    if (test_mode == .Initialisation) {
        // Add some test files for the ramdisk runtime tests
        try ramdisk_files_al.append("test/ramdisk_test1.txt");
        try ramdisk_files_al.append("test/ramdisk_test2.txt");
    } else if (test_mode == .Scheduler) {
        // Add some test files for the user mode runtime tests
        const user_program = b.addAssemble("user_program", "test/user_program.s");
        user_program.setOutputDir(b.install_path);
        user_program.setTarget(target);
        user_program.setBuildMode(build_mode);
        user_program.strip = true;

        const user_program_path = try std.mem.join(b.allocator, "/", &[_][]const u8{ b.install_path, "user_program" });
        const user_program_obj_path = try std.mem.join(b.allocator, "/", &[_][]const u8{ b.install_path, "user_program.o" });
        const copy_user_program = b.addSystemCommand(&[_][]const u8{ "objcopy", "-O", "binary", user_program_obj_path, user_program_path });

        copy_user_program.step.dependOn(&user_program.step);
        try ramdisk_files_al.append(user_program_path);
        exec.step.dependOn(&copy_user_program.step);
    }

    const ramdisk_step = RamdiskStep.create(b, target, ramdisk_files_al.toOwnedSlice(), ramdisk_path);
    make_iso.step.dependOn(&ramdisk_step.step);

    var make_bootable = make_iso;

    // Making the boot image is for the 64 bit port
    switch (target.getCpuArch()) {
        .i386 => b.default_step.dependOn(&make_iso.step),
        .x86_64 => {
            const boot_drive_image = try b.allocator.create(std.fs.File);
            errdefer b.allocator.destroy(boot_drive_image);

            try std.fs.cwd().makePath(b.install_path);
            boot_drive_image.* = try std.fs.cwd().createFile(boot_drive_image_path, .{ .read = true });

            // If there was an error, delete the image as this will be invalid
            errdefer (std.fs.cwd().deleteFile(boot_drive_image_path) catch unreachable);

            var files_path = ArrayList(FromTo).init(b.allocator);
            defer files_path.deinit();
            try files_path.append(.{ .from = "./limine.cfg", .to = "limine.cfg" });
            try files_path.append(.{ .from = "./limine/limine.sys", .to = "limine.sys" });
            try files_path.append(.{ .from = exec.getOutputPath(), .to = "pluto.elf" });
            try files_path.append(.{ .from = ramdisk_path, .to = "initrd.ramdisk" });
            try files_path.append(.{ .from = kernel_map_path, .to = "kernel.map" });

            const mbr_builder_options = BootDriveStep(@TypeOf(boot_drive_image)).Options{
                .mbr_options = .{
                    .partition_options = .{ 100, null, null, null },
                    .image_size = (makefs.Fat32.Options{}).image_size + makefs.MBRPartition.getReservedStartSize(),
                },
                .fs_type = BootDriveStep(@TypeOf(boot_drive_image)).FSType{ .FAT32 = .{} },
            };
            const make_boot_drive_step = BootDriveStep(@TypeOf(boot_drive_image)).create(b, mbr_builder_options, boot_drive_image, files_path.toOwnedSlice());

            make_bootable = b.addSystemCommand(&[_][]const u8{ "./limine/limine-install", boot_drive_image_path });

            make_boot_drive_step.step.dependOn(&make_iso.step);
            make_boot_drive_step.step.dependOn(&ramdisk_step.step);
            make_bootable.step.dependOn(&make_boot_drive_step.step);
            b.default_step.dependOn(&make_bootable.step);
        },
        else => unreachable,
    }

    const test_step = b.step("test", "Run tests");
    const mock_path = "../../test/mock/kernel/";
    const arch_mock_path = "../../../../../test/mock/kernel/";
    const unit_tests = b.addTest(main_src);
    unit_tests.setBuildMode(build_mode);
    unit_tests.setMainPkgPath(".");
    unit_tests.addBuildOption(TestMode, "test_mode", test_mode);
    unit_tests.addBuildOption([]const u8, "mock_path", mock_path);
    unit_tests.addBuildOption([]const u8, "arch_mock_path", arch_mock_path);
    unit_tests.setTarget(.{ .cpu_arch = target.cpu_arch });

    if (builtin.os.tag != .windows) {
        unit_tests.enable_qemu = true;
    }

    // Run the mock gen
    const mock_gen = b.addExecutable("mock_gen", "test/gen_types.zig");
    mock_gen.setMainPkgPath(".");
    const mock_gen_run = mock_gen.run();
    unit_tests.step.dependOn(&mock_gen_run.step);

    const test_fat32_image = try b.allocator.create(std.fs.File);
    errdefer b.allocator.destroy(test_fat32_image);

    // Open the out file
    test_fat32_image.* = try std.fs.cwd().createFile(test_fat32_image_path, .{ .read = true });

    // If there was an error, delete the image as this will be invalid
    errdefer (std.fs.cwd().deleteFile(test_fat32_image_path) catch unreachable);

    const test_files_path = &[_]FromTo{};

    // Create test FAT32 image
    const test_fat32_img_step = Fat32BuilderStep(@TypeOf(test_fat32_image)).create(b, .{}, test_fat32_image, test_files_path);
    const copy_test_files_step = b.addSystemCommand(&[_][]const u8{ "./fat32_cp.sh", test_fat32_image_path });
    copy_test_files_step.step.dependOn(&test_fat32_img_step.step);
    unit_tests.step.dependOn(&copy_test_files_step.step);

    test_step.dependOn(&unit_tests.step);

    const rt_test_step = b.step("rt-test", "Run runtime tests");
    var qemu_args_al = ArrayList([]const u8).init(b.allocator);
    defer qemu_args_al.deinit();

    switch (target.getCpuArch()) {
        .i386 => try qemu_args_al.append("qemu-system-i386"),
        .x86_64 => try qemu_args_al.append("qemu-system-x86_64"),
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
        .x86_64 => {
            try qemu_args_al.append("-drive");
            try qemu_args_al.append(try std.mem.join(b.allocator, "", &[_][]const u8{ "format=raw,file=", boot_drive_image_path }));
        },
        else => unreachable,
    }
    if (disable_display) {
        try qemu_args_al.append("-display");
        try qemu_args_al.append("none");
    }

    var qemu_args = qemu_args_al.toOwnedSlice();

    // 64 bit build don't have full support for these tests yet
    if (target.getCpuArch() == .i386) {
        const rt_step = RuntimeStep.create(b, test_mode, qemu_args);
        rt_step.step.dependOn(&make_bootable.step);
        rt_test_step.dependOn(&rt_step.step);
    }

    const run_step = b.step("run", "Run with qemu");
    const run_debug_step = b.step("debug-run", "Run with qemu and wait for a gdb connection");

    const qemu_cmd = b.addSystemCommand(qemu_args);
    const qemu_debug_cmd = b.addSystemCommand(qemu_args);
    qemu_debug_cmd.addArgs(&[_][]const u8{ "-s", "-S" });

    qemu_cmd.step.dependOn(&make_bootable.step);
    qemu_debug_cmd.step.dependOn(&make_bootable.step);

    run_step.dependOn(&qemu_cmd.step);
    run_debug_step.dependOn(&qemu_debug_cmd.step);

    const debug_step = b.step("debug", "Debug with gdb and connect to a running qemu instance");
    const symbol_file_arg = try std.mem.join(b.allocator, " ", &[_][]const u8{ "symbol-file", exec.getOutputPath() });
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

/// The step to create a bootable drive.
fn BootDriveStep(comptime StreamType: type) type {
    return struct {
        /// The Step, that is all you need to know
        step: Step,

        /// The builder pointer, also all you need to know
        builder: *Builder,

        /// The stream to write the boot drive to.
        stream: StreamType,

        /// Options for creating the MBR partition scheme.
        options: Options,

        /// The list of file paths to copy into the partition created image.
        files: []const FromTo,

        const Self = @This();

        /// The union of filesystems that the partition scheme will use to format the partition
        /// with. TODO: Support multiple partitions with different filesystem types.
        const FSType = union(enum) {
            /// The FAT32 filesystem with the make FAT32 options.
            FAT32: makefs.Fat32.Options,
        };

        /// The options for creating the boot drive.
        const Options = struct {
            /// The MBR options for creating the boot drive.
            mbr_options: makefs.MBRPartition.Options,

            /// The filesystem type to format the boot drive with.
            fs_type: FSType,
        };

        ///
        /// The make function that is called by the builder.
        ///
        /// Arguments:
        ///     IN step: *Step - The step of this step.
        ///
        /// Error: anyerror
        ///     There are too many error to type out but errors will relate to allocation errors
        ///     and file open, read, write and seek.
        ///
        fn make(step: *Step) anyerror!void {
            const self = @fieldParentPtr(Self, "step", step);
            // TODO: Here check the options for what FS for what partition
            try makefs.MBRPartition.make(self.options.mbr_options, self.stream);
            const mbr_fs = &(try mbr_driver.MBRPartition(StreamType).init(self.builder.allocator, self.stream));
            switch (self.options.fs_type) {
                .FAT32 => |*options| {
                    const partition_stream = &(try mbr_fs.getPartitionStream(0));
                    // Overwrite the image size to what we have
                    options.image_size = @intCast(u32, try partition_stream.seekableStream().getEndPos());
                    try Fat32BuilderStep(*mbr_driver.PartitionStream(StreamType)).make2(self.builder.allocator, options.*, partition_stream, self.files);
                },
            }
        }

        ///
        /// Create a boot drive step.
        ///
        /// Arguments:
        ///     IN builder: *Builder     - The builder.
        ///     IN options: Options      - The options used to configure the boot drive.
        ///     IN stream: StreamType    - The stream to write the boot drive to.
        ///     IN files: []const FromTo - The files to copy to the boot drive using the filesystem type.
        ///
        /// Return: *Self
        ///     Pointer to the boot drive step.
        ///
        pub fn create(builder: *Builder, options: Options, stream: StreamType, files: []const FromTo) *Self {
            const boot_driver_step = builder.allocator.create(Self) catch unreachable;
            boot_driver_step.* = .{
                .step = Step.init(.Custom, builder.fmt("BootDriveStep", .{}), builder.allocator, make),
                .builder = builder,
                .stream = stream,
                .options = options,
                .files = files,
            };
            return boot_driver_step;
        }
    };
}

///
/// The FAT32 step for creating a FAT32 image. This now takes a stream type.
///
/// Arguments:
///     IN comptime StreamType: type - The stream type the FAT32 builder step will use.
///
/// Return: type
///     The types FAT32 builder step.
///
fn Fat32BuilderStep(comptime StreamType: type) type {
    return struct {
        /// The Step, that is all you need to know
        step: Step,

        /// The builder pointer, also all you need to know
        builder: *Builder,

        /// The stream to write the FAT32 headers and files to.
        stream: StreamType,

        /// Options for creating the FAT32 image.
        options: makefs.Fat32.Options,

        /// The list of file paths to copy into the FAT32 image.
        files: []const FromTo,

        const Self = @This();

        ///
        /// The make function that is called by the builder.
        ///
        /// Arguments:
        ///     IN step: *Step - The step of this step.
        ///
        /// Error: anyerror
        ///     There are too many error to type out but errors will relate to allocation errors
        ///     and file open, read, write and seek.
        ///
        fn make(step: *Step) anyerror!void {
            const self = @fieldParentPtr(Self, "step", step);
            try make2(self.builder.allocator, self.options, self.stream, self.files);
        }

        ///
        /// A standard method for making a FAT32 filesystem on a stream already partitioned.
        ///
        /// Arguments:
        ///     IN allocator: *Allocator         - An allocator for memory allocation.
        ///     IN options: makefs.Fat32.Options - The options to make a FAT32 filesystem.
        ///     IN stream: StreamType            - The stream to write the filesystem to. This will
        ///                                        be from a getPartitionStream().
        ///     IN files: []const FromTo         - The file to write to the file system.
        ///
        /// Error: anyerror
        ///     There are too many error to type out but errors will relate to allocation errors
        ///     and file open, read, write and seek.
        ///
        pub fn make2(allocator: *Allocator, options: makefs.Fat32.Options, stream: StreamType, files: []const FromTo) anyerror!void {
            try makefs.Fat32.make(options, stream);

            // Copy the files into the image
            var fat32_image = try fat32_driver.initialiseFAT32(allocator, stream);
            defer fat32_image.destroy() catch unreachable;
            for (files) |file_path| {
                const opened_node = try fat32_image.fs.open(fat32_image.fs, &fat32_image.root_node.node.Dir, file_path.to, .CREATE_FILE, .{});
                const opened_file = &opened_node.File;
                defer opened_file.close();

                const orig_file = try std.fs.cwd().openFile(file_path.from, .{});
                defer orig_file.close();

                // TODO: Might need to increase max size of files get too big.
                const orig_content = try orig_file.readToEndAlloc(allocator, 10 * 1024 * 1024);

                _ = try opened_file.write(orig_content);
            }
        }

        ///
        /// Create a FAT32 builder step.
        ///
        /// Argument:
        ///     IN builder: *Builder     - The build builder.
        ///     IN options: Options      - Options for creating FAT32 image.
        ///     IN stream: StreamType    - The stream to write the FAT32 image to.
        ///     IN files: []const FromTo - The list of file paths to copy into the FAT32 image.
        ///
        /// Return: *Self
        ///     The FAT32 builder step pointer to add to the build process.
        ///
        pub fn create(builder: *Builder, options: makefs.Fat32.Options, stream: StreamType, files: []const FromTo) *Self {
            const fat32_builder_step = builder.allocator.create(Self) catch unreachable;
            fat32_builder_step.* = .{
                .step = Step.init(.Custom, builder.fmt("Fat32BuilderStep", .{}), builder.allocator, make),
                .builder = builder,
                .options = options,
                .stream = stream,
                .files = files,
            };
            return fat32_builder_step;
        }
    };
}

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
    const Error = (error{ EndOfStream, FileTooBig } || Allocator.Error || File.ReadError || File.GetSeekPosError || File.WriteError || File.OpenError);

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
            .x86_64 => try writeRamdisk(u64, self),
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
            .step = Step.init(.Custom, builder.fmt("Ramdisk", .{}), builder.allocator, make),
            .builder = builder,
            .target = target,
            .files = files,
            .out_file_path = out_file_path,
        };
        return ramdisk_step;
    }
};

pub const struct_stivale2_tag = packed struct {
    identifier: u64,
    next: u64,
};
pub const struct_stivale2_header = packed struct {
    entry_point: u64,
    stack: u64,
    flags: u64,
    tags: u64,
};
pub const struct_stivale2_header_tag_framebuffer = packed struct {
    tag: struct_stivale2_tag,
    framebuffer_width: u16,
    framebuffer_height: u16,
    framebuffer_bpp: u16,
};
pub const struct_stivale2_header_tag_smp = packed struct {
    tag: struct_stivale2_tag,
    flags: u64,
};
pub const struct_stivale2_struct = packed struct {
    bootloader_brand: [64]u8,
    bootloader_version: [64]u8,
    tags: u64,
};
pub const struct_stivale2_struct_tag_cmdline = packed struct {
    tag: struct_stivale2_tag,
    cmdline: u64,
};
pub const STIVALE2_MMAP_USABLE = @enumToInt(enum_unnamed_1.STIVALE2_MMAP_USABLE);
pub const STIVALE2_MMAP_RESERVED = @enumToInt(enum_unnamed_1.STIVALE2_MMAP_RESERVED);
pub const STIVALE2_MMAP_ACPI_RECLAIMABLE = @enumToInt(enum_unnamed_1.STIVALE2_MMAP_ACPI_RECLAIMABLE);
pub const STIVALE2_MMAP_ACPI_NVS = @enumToInt(enum_unnamed_1.STIVALE2_MMAP_ACPI_NVS);
pub const STIVALE2_MMAP_BAD_MEMORY = @enumToInt(enum_unnamed_1.STIVALE2_MMAP_BAD_MEMORY);
pub const STIVALE2_MMAP_BOOTLOADER_RECLAIMABLE = @enumToInt(enum_unnamed_1.STIVALE2_MMAP_BOOTLOADER_RECLAIMABLE);
pub const STIVALE2_MMAP_KERNEL_AND_MODULES = @enumToInt(enum_unnamed_1.STIVALE2_MMAP_KERNEL_AND_MODULES);
const enum_unnamed_1 = extern enum(c_int) {
    STIVALE2_MMAP_USABLE = 1,
    STIVALE2_MMAP_RESERVED = 2,
    STIVALE2_MMAP_ACPI_RECLAIMABLE = 3,
    STIVALE2_MMAP_ACPI_NVS = 4,
    STIVALE2_MMAP_BAD_MEMORY = 5,
    STIVALE2_MMAP_BOOTLOADER_RECLAIMABLE = 4096,
    STIVALE2_MMAP_KERNEL_AND_MODULES = 4097,
    _,
};
pub const struct_stivale2_mmap_entry = packed struct {
    base: u64,
    length: u64,
    entry_type: u32,
    unused: u32,
};
pub const struct_stivale2_struct_tag_memmap = packed struct {
    tag: struct_stivale2_tag,
    entries: u64,
    memmap: u64,
};
pub const STIVALE2_FBUF_MMODEL_RGB = @enumToInt(enum_unnamed_2.STIVALE2_FBUF_MMODEL_RGB);
const enum_unnamed_2 = extern enum(c_int) {
    STIVALE2_FBUF_MMODEL_RGB = 1,
    _,
};
pub const struct_stivale2_struct_tag_framebuffer = packed struct {
    tag: struct_stivale2_tag,
    framebuffer_addr: u64,
    framebuffer_width: u16,
    framebuffer_height: u16,
    framebuffer_pitch: u16,
    framebuffer_bpp: u16,
    memory_model: u8,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
};
pub const struct_stivale2_module = packed struct {
    begin: u64,
    end: u64,
    string: [128]u8,
};
pub const struct_stivale2_struct_tag_modules = packed struct {
    tag: struct_stivale2_tag,
    module_count: u64,
    modules: u64,
};
pub const struct_stivale2_struct_tag_rsdp = packed struct {
    tag: struct_stivale2_tag,
    rsdp: u64,
};
pub const struct_stivale2_struct_tag_epoch = packed struct {
    tag: struct_stivale2_tag,
    epoch: u64,
};
pub const struct_stivale2_struct_tag_firmware = packed struct {
    tag: struct_stivale2_tag,
    flags: u64,
};
pub const struct_stivale2_smp_info = packed struct {
    processor_id: u32,
    lapic_id: u32,
    target_stack: u64,
    goto_address: u64,
    extra_argument: u64,
};
pub const struct_stivale2_struct_tag_smp = packed struct {
    tag: struct_stivale2_tag,
    flags: u64,
    bsp_lapic_id: u32,
    unused: u32,
    cpu_count: u64,
    smp_info: u64,
};

pub const STIVALE2_HEADER_TAG_FRAMEBUFFER_ID = 0x3ecc1bc43d0f7971;
pub const STIVALE2_HEADER_TAG_SMP_ID = 0x1ab015085f3273df;
pub const STIVALE2_HEADER_TAG_5LV_PAGING_ID = 0x932f477032007e8f;
pub const STIVALE2_BOOTLOADER_BRAND_SIZE = 64;
pub const STIVALE2_BOOTLOADER_VERSION_SIZE = 64;
pub const STIVALE2_STRUCT_TAG_CMDLINE_ID = 0xe5e76a1b4597a781;
pub const STIVALE2_STRUCT_TAG_MEMMAP_ID = 0x2187f79e8612de07;
pub const STIVALE2_STRUCT_TAG_FRAMEBUFFER_ID = 0x506461d2950408fa;
pub const STIVALE2_STRUCT_TAG_MODULES_ID = 0x4b6fe466aade04ce;
pub const STIVALE2_MODULE_STRING_SIZE = 128;
pub const STIVALE2_STRUCT_TAG_RSDP_ID = 0x9e1786930a375e78;
pub const STIVALE2_STRUCT_TAG_EPOCH_ID = 0x566a7bed888e1407;
pub const STIVALE2_STRUCT_TAG_FIRMWARE_ID = 0x359d837855e3858c;
pub const STIVALE2_STRUCT_TAG_SMP_ID = 0x34d1d96339647025;
pub const stivale2_tag = struct_stivale2_tag;
pub const stivale2_header = struct_stivale2_header;
pub const stivale2_header_tag_framebuffer = struct_stivale2_header_tag_framebuffer;
pub const stivale2_header_tag_smp = struct_stivale2_header_tag_smp;
pub const stivale2_struct = struct_stivale2_struct;
pub const stivale2_struct_tag_cmdline = struct_stivale2_struct_tag_cmdline;
pub const stivale2_mmap_entry = struct_stivale2_mmap_entry;
pub const stivale2_struct_tag_memmap = struct_stivale2_struct_tag_memmap;
pub const stivale2_struct_tag_framebuffer = struct_stivale2_struct_tag_framebuffer;
pub const stivale2_module = struct_stivale2_module;
pub const stivale2_struct_tag_modules = struct_stivale2_struct_tag_modules;
pub const stivale2_struct_tag_rsdp = struct_stivale2_struct_tag_rsdp;
pub const stivale2_struct_tag_epoch = struct_stivale2_struct_tag_epoch;
pub const stivale2_struct_tag_firmware = struct_stivale2_struct_tag_firmware;
pub const stivale2_smp_info = struct_stivale2_smp_info;
pub const stivale2_struct_tag_smp = struct_stivale2_struct_tag_smp;

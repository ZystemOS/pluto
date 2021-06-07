const std = @import("std");
const builtin = @import("builtin");
const is_test = builtin.is_test;
const expectEqual = std.testing.expectEqual;
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const log = std.log.scoped(.pci);
const arch = if (is_test) @import("../../../../test/mock/kernel/arch_mock.zig") else @import("arch.zig");

/// The port address for selecting a 32bit register in the PCI configuration space.
const CONFIG_ADDRESS: u16 = 0x0CF8;

/// The port address for read/writing to the selected address.
const CONFIG_DATA: u16 = 0x0CFC;

/// The register offsets for PCI. Currently there is no check for valid register offsets for the
/// header type. The names are self explanatory. Further information can be found here:
/// https://wiki.osdev.org/PCI.
const PciRegisters = enum(u8) {
    VenderId = 0x00,
    DeviceId = 0x02,
    Command = 0x04,
    Status = 0x06,
    RevisionId = 0x08,
    ProgrammingInterface = 0x09,
    Subclass = 0x0A,
    ClassCode = 0x0B,
    CacheLineSize = 0x0C,
    LatencyTimer = 0x0D,
    HeaderType = 0x0E,
    BIST = 0x0F,

    // The next set of registers are for the 0x00 (standard) header.
    // This currently uses only the common registers above that are available to all header types.

    BaseAddr0 = 0x10,
    BaseAddr1 = 0x14,
    BaseAddr2 = 0x18,
    BaseAddr3 = 0x1C,
    BaseAddr4 = 0x20,
    BaseAddr5 = 0x24,
    CardbusCISPtr = 0x28,
    SubsystemVenderId = 0x2C,
    SubsystemId = 0x2E,
    ExpansionROMBaseAddr = 0x30,
    CapabilitiesPtr = 0x34,
    InterruptLine = 0x3C,
    InterruptPin = 0x3D,
    MinGrant = 0x3E,
    MaxLatency = 0x3F,

    ///
    /// Get the type the represents the width of the register. This can be either u8, u16 or u32.
    ///
    /// Argument:
    ///     IN comptime pci_reg: PciRegisters - The register to get the width for.
    ///
    /// Return: type
    ///     The width type.
    ///
    pub fn getWidth(comptime pci_reg: PciRegisters) type {
        return switch (pci_reg) {
            .RevisionId, .ProgrammingInterface, .Subclass, .ClassCode, .CacheLineSize, .LatencyTimer, .HeaderType, .BIST, .InterruptLine, .InterruptPin, .MinGrant, .MaxLatency, .CapabilitiesPtr => u8,
            .VenderId, .DeviceId, .Command, .Status, .SubsystemVenderId, .SubsystemId => u16,
            .BaseAddr0, .BaseAddr1, .BaseAddr2, .BaseAddr3, .BaseAddr4, .BaseAddr5, .CardbusCISPtr, .ExpansionROMBaseAddr => u32,
        };
    }
};

/// The PCI address used for sending to the address port.
const PciAddress = packed struct {
    register_offset: u8,
    function: u3,
    device: u5,
    bus: u8,
    reserved: u7 = 0,
    enable: u1 = 1,
};

/// A PCI device. This will be unique to a bus and device number.
const PciDevice = struct {
    /// The bus on which the device is on
    bus: u8,

    /// The device number.
    device: u5,

    const Self = @This();

    ///
    /// Get the PCI address for this device and for a function and register.
    ///
    /// Argument:
    ///     IN self: Self                     - This device.
    ///     IN function: u3                   - The function.
    ///     IN comptime pci_reg: PciRegisters - The register.
    ///
    /// Return: PciAddress
    ///     The PCI address that can be used to read the register offset for this device and function.
    ///
    pub fn getAddress(self: Self, function: u3, comptime pci_reg: PciRegisters) PciAddress {
        return PciAddress{
            .bus = self.bus,
            .device = self.device,
            .function = function,
            .register_offset = @enumToInt(pci_reg),
        };
    }

    ///
    /// Read the configuration register data from this device, function and register. PCI configure
    /// reads will return a u32 value, but the register may not be u32 is size so this will return
    /// the correctly typed value depending on the size of the register.
    ///
    /// Argument:
    ///     IN self: Self                     - This device.
    ///     IN function: u3                   - The function.
    ///     IN comptime pci_reg: PciRegisters - The register.
    ///
    /// Return: PciRegisters.getWidth()
    ///     Depending on the register, the type of the return value maybe u8, u16 or u32. See
    ///     PciRegisters.getWidth().
    ///
    pub fn configReadData(self: Self, function: u3, comptime pci_reg: PciRegisters) pci_reg.getWidth() {
        const address = self.getAddress(function, pci_reg);
        // Last 2 bits of offset must be zero
        // This is because we are requesting a integer (4 bytes) and cannot request a
        // single byte that isn't 4 bytes aligned
        // Write the address
        arch.out(CONFIG_ADDRESS, @bitCast(u32, address) & 0xFFFFFFFC);
        // Read the data
        const result = arch.in(u32, CONFIG_DATA);
        // Return the size the user wants
        const shift = switch (pci_reg.getWidth()) {
            u8 => (@intCast(u5, address.register_offset & 0x3)) * 8,
            u16 => (@intCast(u5, address.register_offset & 0x2)) * 8,
            u32 => 0,
            else => @compileError("Invalid read size. Only u8, u16 and u32 allowed."),
        };
        return @truncate(pci_reg.getWidth(), (result >> shift));
    }

    test "configReadData u8" {
        arch.initTest();
        defer arch.freeTest();

        // The bus, device and function values can be any value as we are testing the shifting and masking
        // Have chosen bus = 0, device = 1 and function = 2.
        // We only change the register as they will have different but widths.

        {
            const device = PciDevice{
                .bus = 0,
                .device = 1,
            };

            arch.addTestParams("out", .{ CONFIG_ADDRESS, @bitCast(u32, device.getAddress(2, .RevisionId)) & 0xFFFFFFFC });
            arch.addTestParams("in", .{ CONFIG_DATA, @as(u32, 0xABCDEF12) });

            // RevisionId is a u8 width, offset 0
            const res = device.configReadData(2, .RevisionId);
            try expectEqual(res, 0x12);
        }

        {
            const device = PciDevice{
                .bus = 0,
                .device = 1,
            };

            arch.addTestParams("out", .{ CONFIG_ADDRESS, @bitCast(u32, device.getAddress(2, .ProgrammingInterface)) & 0xFFFFFFFC });
            arch.addTestParams("in", .{ CONFIG_DATA, @as(u32, 0xABCDEF12) });

            // ProgrammingInterface is a u8 width, offset 8
            const res = device.configReadData(2, .ProgrammingInterface);
            try expectEqual(res, 0xEF);
        }

        {
            const device = PciDevice{
                .bus = 0,
                .device = 1,
            };

            arch.addTestParams("out", .{ CONFIG_ADDRESS, @bitCast(u32, device.getAddress(2, .Subclass)) & 0xFFFFFFFC });
            arch.addTestParams("in", .{ CONFIG_DATA, @as(u32, 0xABCDEF12) });

            // Subclass is a u8 width, offset 16
            const res = device.configReadData(2, .Subclass);
            try expectEqual(res, 0xCD);
        }

        {
            const device = PciDevice{
                .bus = 0,
                .device = 1,
            };

            arch.addTestParams("out", .{ CONFIG_ADDRESS, @bitCast(u32, device.getAddress(2, .ClassCode)) & 0xFFFFFFFC });
            arch.addTestParams("in", .{ CONFIG_DATA, @as(u32, 0xABCDEF12) });

            // ClassCode is a u8 width, offset 24
            const res = device.configReadData(2, .ClassCode);
            try expectEqual(res, 0xAB);
        }
    }

    test "configReadData u16" {
        arch.initTest();
        defer arch.freeTest();

        // The bus, device and function values can be any value as we are testing the shifting and masking
        // Have chosen bus = 0, device = 1 and function = 2.
        // We only change the register as they will have different but widths.

        {
            const device = PciDevice{
                .bus = 0,
                .device = 1,
            };

            arch.addTestParams("out", .{ CONFIG_ADDRESS, @bitCast(u32, device.getAddress(2, .VenderId)) & 0xFFFFFFFC });
            arch.addTestParams("in", .{ CONFIG_DATA, @as(u32, 0xABCDEF12) });

            // VenderId is a u16 width, offset 0
            const res = device.configReadData(2, .VenderId);
            try expectEqual(res, 0xEF12);
        }

        {
            const device = PciDevice{
                .bus = 0,
                .device = 1,
            };

            arch.addTestParams("out", .{ CONFIG_ADDRESS, @bitCast(u32, device.getAddress(2, .DeviceId)) & 0xFFFFFFFC });
            arch.addTestParams("in", .{ CONFIG_DATA, @as(u32, 0xABCDEF12) });

            // DeviceId is a u16 width, offset 16
            const res = device.configReadData(2, .DeviceId);
            try expectEqual(res, 0xABCD);
        }
    }

    test "configReadData u32" {
        arch.initTest();
        defer arch.freeTest();

        // The bus, device and function values can be any value as we are testing the shifting and masking
        // Have chosen bus = 0, device = 1 and function = 2.
        // We only change the register as they will have different but widths.

        {
            const device = PciDevice{
                .bus = 0,
                .device = 1,
            };

            arch.addTestParams("out", .{ CONFIG_ADDRESS, @bitCast(u32, device.getAddress(2, .BaseAddr0)) & 0xFFFFFFFC });
            arch.addTestParams("in", .{ CONFIG_DATA, @as(u32, 0xABCDEF12) });

            // BaseAddr0 is a u32 width, offset 0
            const res = device.configReadData(2, .BaseAddr0);
            try expectEqual(res, 0xABCDEF12);
        }
    }
};

pub const PciDeviceInfo = struct {
    pci_device: PciDevice,
    function: u3,
    vender_id: u16,
    device_id: u16,
    subclass: u8,
    class_code: u8,

    /// The error set.
    pub const Error = error{
        /// There is no functions available for the given function number for a given PCI device.
        NoFunction,
    };

    pub fn create(pci_device: PciDevice, function: u3) Error!PciDeviceInfo {
        const vender_id = pci_device.configReadData(function, .VenderId);

        // No function available, try the next
        if (vender_id == 0xFFFF) {
            return Error.NoFunction;
        }

        return PciDeviceInfo{
            .pci_device = pci_device,
            .function = function,
            .vender_id = vender_id,
            .device_id = pci_device.configReadData(function, .DeviceId),
            .subclass = pci_device.configReadData(function, .Subclass),
            .class_code = pci_device.configReadData(function, .ClassCode),
        };
    }

    pub fn print(device: arch.Device) void {
        log.info("BUS: 0x{X}, DEV: 0x{X}, FUN: 0x{X}, VID: 0x{X}, DID: 0x{X}, SC: 0x{X}, CC: 0x{X}\n", .{
            device.pci_device.bus,
            device.pci_device.device,
            device.function,
            device.vender_id,
            device.device_id,
            device.subclass,
            device.class_code,
        });
    }
};

///
/// Get a list of all the PCI device. The returned list will needed to be freed by the caller.
///
/// Arguments:
///     IN allocator: Allocator - An allocator used for creating the list.
///
/// Return: []PciDeviceInfo
///     The list of PCI devices information.
///
/// Error: Allocator.Error
///     error.OutOfMemory - If there isn't enough memory to create the info list.
///
pub fn getDevices(allocator: Allocator) Allocator.Error![]PciDeviceInfo {
    // Create an array list for the devices.
    var pci_device_infos = ArrayList(PciDeviceInfo).init(allocator);
    defer pci_device_infos.deinit();

    // Iterate through all the possible devices
    var _bus: u32 = 0;
    while (_bus < 8) : (_bus += 1) {
        const bus = @intCast(u8, _bus);
        var _device: u32 = 0;
        while (_device < 32) : (_device += 1) {
            const device = @intCast(u5, _device);
            // Devices have at least 1 function
            const pci_device = PciDevice{
                .bus = bus,
                .device = device,
            };
            var num_functions: u32 = if (pci_device.configReadData(0, .HeaderType) & 0x80 != 0) 8 else 1;
            var _function: u32 = 0;
            while (_function < num_functions) : (_function += 1) {
                const function = @intCast(u3, _function);
                const device_info = PciDeviceInfo.create(pci_device, function) catch |e| switch (e) {
                    error.NoFunction => continue,
                };

                try pci_device_infos.append(device_info);
            }
        }
    }

    return pci_device_infos.toOwnedSlice();
}

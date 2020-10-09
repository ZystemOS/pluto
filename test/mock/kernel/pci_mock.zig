const std = @import("std");
const Allocator = std.mem.Allocator;
const arch = @import("arch_mock.zig");

const mock_framework = @import("mock_framework.zig");
pub const initTest = mock_framework.initTest;
pub const freeTest = mock_framework.freeTest;
pub const addTestParams = mock_framework.addTestParams;
pub const addConsumeFunction = mock_framework.addConsumeFunction;
pub const addRepeatFunction = mock_framework.addRepeatFunction;

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

    pub fn getWidth(comptime pci_reg: PciRegisters) type {
        return switch (pci_reg) {
            .RevisionId, .ProgrammingInterface, .Subclass, .ClassCode, .CacheLineSize, .LatencyTimer, .HeaderType, .BIST, .InterruptLine, .InterruptPin, .MinGrant, .MaxLatency, .CapabilitiesPtr => u8,
            .VenderId, .DeviceId, .Command, .Status, .SubsystemVenderId, .SubsystemId => u16,
            .BaseAddr0, .BaseAddr1, .BaseAddr2, .BaseAddr3, .BaseAddr4, .BaseAddr5, .CardbusCISPtr, .ExpansionROMBaseAddr => u32,
        };
    }
};

const PciAddress = packed struct {
    register_offset: u8,
    function: u3,
    device: u5,
    bus: u8,
    reserved: u7 = 0,
    enable: u1 = 1,
};

const PciDevice = struct {
    bus: u8,
    device: u5,

    const Self = @This();

    pub fn getAddress(self: Self, function: u3, comptime pci_reg: PciRegisters) PciAddress {
        return PciAddress{
            .bus = self.bus,
            .device = self.device,
            .function = function,
            .register_offset = @enumToInt(pci_reg),
        };
    }

    pub fn configReadData(self: Self, function: u3, comptime pci_reg: PciRegisters) pci_reg.getWidth() {
        return mock_framework.performAction("PciDevice.configReadData", pci_reg.getWidth(), .{ self, function, pci_reg });
    }
};

pub const PciDeviceInfo = struct {
    pci_device: PciDevice,
    function: u3,
    vender_id: u16,
    device_id: u16,
    subclass: u8,
    class_code: u8,

    pub const Error = error{NoFunction};

    pub fn create(pci_device: PciDevice, function: u3) Error!PciDeviceInfo {
        return mock_framework.performAction("PciDeviceInfo.create", Error!PciDeviceInfo, .{ pci_device, function });
    }

    pub fn print(device: arch.Device) void {
        std.debug.print("BUS: 0x{X}, DEV: 0x{X}, FUN: 0x{X}, VID: 0x{X}, DID: 0x{X}, SC: 0x{X}, CC: 0x{X}\n", .{
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

pub fn getDevices(allocator: *Allocator) Allocator.Error![]PciDeviceInfo {
    return mock_framework.performAction("getDevices", Allocator.Error![]PciDeviceInfo, .{allocator});
}

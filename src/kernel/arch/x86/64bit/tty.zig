/// The location of the kernel in virtual memory so can calculate the address of the VGA buffer
extern var KERNEL_ADDR_OFFSET: *u32;

///
/// Gets the video buffer's virtual address.
///
/// Return: usize
///     The virtual address of the video buffer
///
pub fn getVideoBufferAddress() usize {
    return @ptrToInt(&KERNEL_ADDR_OFFSET) + 0xB8000;
}

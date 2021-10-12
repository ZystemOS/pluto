const std = @import("std");
const fmt = std.fmt;
const builtin = std.builtin;
const is_test = builtin.is_test;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const log = std.log.scoped(.x86_tty);
const build_options = @import("build_options");
const vga = if (is_test) @import("../../../../test/mock/kernel/vga_mock.zig") else @import("vga.zig");
const panic = @import("../../panic.zig").panic;

/// The error set for if there is an error whiles printing.
const TtyError = error{
    /// If the printing tries to print outside the video buffer.
    OutOfBounds,
};

/// The number of rows down from the top (row 0) where the displayable region starts. Above is
/// where the logo and time is printed
const ROW_MIN: u16 = 7;

/// The total number of rows in the displayable region
const ROW_TOTAL: u16 = vga.HEIGHT - ROW_MIN;

/// The total number of pages (static) that the terminal will remember. In the future, this can
/// move to a more dynamic allocation when a kheap is implemented.
const TOTAL_NUM_PAGES: u16 = 5;

/// The total number of VGA (or characters) elements are on a page
const TOTAL_CHAR_ON_PAGE: u16 = vga.WIDTH * ROW_TOTAL;

/// The start of the displayable region in the video buffer memory
const START_OF_DISPLAYABLE_REGION: u16 = vga.WIDTH * ROW_MIN;

/// The total number of VGA elements (or characters) the video buffer can display
const VIDEO_BUFFER_SIZE: u16 = vga.WIDTH * vga.HEIGHT;

/// The location of the kernel in virtual memory so can calculate the address of the VGA buffer
extern var KERNEL_ADDR_OFFSET: *u32;

/// The current x position of the cursor.
var column: u8 = 0;

/// The current y position of the cursor.
var row: u8 = 0;

/// The current colour of the display with foreground and background colour.
var colour: u8 = undefined;

/// The buffer starting from the beginning of the video memory location that contains all data
/// written to the display.
var video_buffer: []volatile u16 = undefined;

/// The blank VGA entry to be used to clear the screen.
var blank: u16 = undefined;

/// A total of TOTAL_NUM_PAGES pages that can be saved and restored to from and to the video buffer
var pages: [TOTAL_NUM_PAGES][TOTAL_CHAR_ON_PAGE]u16 = init: {
    var p: [TOTAL_NUM_PAGES][TOTAL_CHAR_ON_PAGE]u16 = undefined;

    for (p) |*page| {
        page.* = [_]u16{0} ** TOTAL_CHAR_ON_PAGE;
    }

    break :init p;
};

/// The current page index.
var page_index: u8 = 0;

///
/// Copies data into the video buffer. This is used for copying a page into the video buffer.
///
/// Arguments:
///     IN video_buf_offset: u16 - The offset into the video buffer to start copying to.
///     IN data: []const u16     - The data to copy into the video buffer.
///     IN size: u16             - The amount to copy.
///
/// Errors: TtyError
///     TtyError.OutOfBounds - If offset or the size to copy is greater than the size of the
///                            video buffer or data to copy.
///
fn videoCopy(video_buf_offset: u16, data: []const u16, size: u16) TtyError!void {
    // Secure programming ;)
    if (video_buf_offset >= video_buffer.len and
        size > video_buffer.len - video_buf_offset and
        size > data.len)
    {
        return TtyError.OutOfBounds;
    }

    var i: u32 = 0;
    while (i < size) : (i += 1) {
        video_buffer[video_buf_offset + i] = data[i];
    }
}

///
/// Moves data with a page without overriding itself.
///
/// Arguments:
///     IN dest: []u16 - The destination position to copy into.
///     IN src: []u16  - The source position to copy from.
///     IN size: u16   - The amount to copy.
///
/// Errors:
///     TtyError.OutOfBounds - If the size to copy is greater than the size of the pages.
///
fn pageMove(dest: []u16, src: []u16, size: u16) TtyError!void {
    if (dest.len < size or src.len < size) {
        return TtyError.OutOfBounds;
    }

    // Not an error if size is zero, nothing will be copied
    if (size == 0) return;

    // Make sure we don't override the values we want to copy
    if (@ptrToInt(&dest[0]) < @ptrToInt(&src[0])) {
        var i: u16 = 0;
        while (i != size) : (i += 1) {
            dest[i] = src[i];
        }
    } else {
        var i = size;
        while (i != 0) {
            i -= 1;
            dest[i] = src[i];
        }
    }
}

///
/// Clears a region of the video buffer to a VGA entry from the beginning.
///
/// Arguments:
///     IN c: u16    - VGA entry to set the video buffer to.
///     IN size: u16 - The number to VGA entries to set from the beginning of the video buffer.
///
/// Errors:
///     TtyError.OutOfBounds - If the size to copy is greater than the size of the video buffer.
///
fn setVideoBuffer(c: u16, size: u16) TtyError!void {
    if (size > VIDEO_BUFFER_SIZE) {
        return TtyError.OutOfBounds;
    }

    for (video_buffer[0..size]) |*b| {
        b.* = c;
    }
}

///
/// Updated the hardware cursor to the current column and row (x, y).
///
fn updateCursor() void {
    vga.updateCursor(column, row);
}

///
/// Get the hardware cursor and set the current column and row (x, y).
///
fn getCursor() void {
    const cursor = vga.getCursor();

    row = @truncate(u8, cursor / vga.WIDTH);
    column = @truncate(u8, cursor % vga.WIDTH);
}

///
/// Put a character at a specific column and row position on the screen. This will use the current
/// colour.
///
/// Arguments:
///     IN char: u8 - The character to print. This will be combined with the current colour.
///     IN x: u8    - The x position (column) to put the character at.
///     IN y: u8    - The y position (row) to put the character at.
///
/// Errors:
///     TtyError.OutOfBounds - If trying to print outside the video buffer.
///
fn putEntryAt(char: u8, x: u8, y: u8) TtyError!void {
    const index = y * vga.WIDTH + x;

    // Bounds check
    if (index >= VIDEO_BUFFER_SIZE) {
        return TtyError.OutOfBounds;
    }

    const char_entry = vga.entry(char, colour);

    if (index >= START_OF_DISPLAYABLE_REGION) {
        // If not at page zero, (bottom of page), then display that page
        // The user has move up a number of pages and then typed a letter, so need to move to the
        // 0'th page
        if (page_index != 0) {
            // This isn't out of bounds
            page_index = 0;
            try videoCopy(START_OF_DISPLAYABLE_REGION, pages[page_index][0..TOTAL_CHAR_ON_PAGE], TOTAL_CHAR_ON_PAGE);

            // If not on page 0, then the cursor would have been disabled
            vga.enableCursor();
            updateCursor();
        }
        pages[page_index][index - START_OF_DISPLAYABLE_REGION] = char_entry;
    }

    video_buffer[index] = char_entry;
}

///
/// Move rows up pages across multiple pages leaving the last rows blank.
///
/// Arguments:
///     IN rows: u16 - The number of rows to move up.
///
/// Errors:
///     TtyError.OutOfBounds - If trying to move up more rows on a page.
///
fn pagesMoveRowsUp(rows: u16) TtyError!void {
    // Out of bounds check
    if (rows > ROW_TOTAL) {
        return TtyError.OutOfBounds;
    }

    // Not an error to move 0 rows, but is pointless
    if (rows == 0) return;

    // Move up rows in last page up by "rows"
    const row_length = rows * vga.WIDTH;
    const chars_to_move = (ROW_TOTAL - rows) * vga.WIDTH;
    try pageMove(pages[TOTAL_NUM_PAGES - 1][0..chars_to_move], pages[TOTAL_NUM_PAGES - 1][row_length..], chars_to_move);

    // Loop for the other pages
    var i = TOTAL_NUM_PAGES - 1;
    while (i > 0) : (i -= 1) {
        try pageMove(pages[i][chars_to_move..], pages[i - 1][0..row_length], row_length);
        try pageMove(pages[i - 1][0..chars_to_move], pages[i - 1][row_length..], chars_to_move);
    }

    // Clear the last lines
    for (pages[0][chars_to_move..]) |*p| {
        p.* = blank;
    }
}

///
/// When the text/terminal gets to the bottom of the screen, then move all line up by the amount
/// that are below the bottom of the screen. Usually moves up by one line.
///
/// Errors:
///     TtyError.OutOfBounds - If trying to move up more rows on a page. This shouldn't happen
///                            as bounds checks have been done.
///
fn scroll() void {
    // Added the condition in the if from pagesMoveRowsUp as don't need to move all rows
    if (row >= vga.HEIGHT and (row - vga.HEIGHT + 1) <= ROW_TOTAL) {
        const rows_to_move = row - vga.HEIGHT + 1;

        // Move rows up pages by temp, will usually be one.
        // TODO: Maybe panic here as we have the check above, so if this fails, then is a big problem
        pagesMoveRowsUp(rows_to_move) catch {
            panic(@errorReturnTrace(), "Can't move {} rows up. Must be less than {}\n", .{ rows_to_move, ROW_TOTAL });
        };

        // Move all rows up by rows_to_move
        var i: u32 = 0;
        while (i < (ROW_TOTAL - rows_to_move) * vga.WIDTH) : (i += 1) {
            video_buffer[START_OF_DISPLAYABLE_REGION + i] = video_buffer[(rows_to_move * vga.WIDTH) + START_OF_DISPLAYABLE_REGION + i];
        }

        // Set the last rows to blanks
        i = 0;
        while (i < vga.WIDTH * rows_to_move) : (i += 1) {
            video_buffer[(vga.HEIGHT - rows_to_move) * vga.WIDTH + i] = blank;
        }

        row = vga.HEIGHT - 1;
    }
}

///
/// Print a character without updating the cursor. For speed when printing a string as only need to
/// update the cursor once. This will also print the special characters: \n, \r, \t and \b. (\b is
/// not a valid character so use \x08 which is the hex value).
///
/// Arguments:
///     IN char: u8 - The character to print.
///
/// Errors:
///     TtyError.OutOfBounds - If trying to scroll more rows on a page/displayable region or
///                            print beyond the video buffer.
///
fn putChar(char: u8) TtyError!void {
    const column_temp = column;
    const row_temp = row;

    // If there was an error, then set the row and column back to where is was
    // Like nothing happened
    errdefer column = column_temp;
    errdefer row = row_temp;

    switch (char) {
        '\n' => {
            column = 0;
            row += 1;
            scroll();
        },
        '\t' => {
            column += 4;
            if (column >= vga.WIDTH) {
                column -= @truncate(u8, vga.WIDTH);
                row += 1;
                scroll();
            }
        },
        '\r' => {
            column = 0;
        },
        // \b
        '\x08' => {
            if (column == 0) {
                if (row != 0) {
                    column = vga.WIDTH - 1;
                    row -= 1;
                }
            } else {
                column -= 1;
            }
        },
        else => {
            try putEntryAt(char, column, row);
            column += 1;
            if (column == vga.WIDTH) {
                column = 0;
                row += 1;
                scroll();
            }
        },
    }
}

///
/// Set the TTY cursor position to a row and column
///
/// Arguments:
///     IN r: u8 - The row to set it to
///     IN col: u8 - The column to set it to
///
pub fn setCursor(r: u8, col: u8) void {
    column = col;
    row = r;
    updateCursor();
}

///
/// Print a string to the TTY. This also updates to hardware cursor.
///
/// Arguments:
///     IN str: []const u8 - The string to print.
///
/// Errors:
///     TtyError.OutOfBounds - If trying to print beyond the video buffer.
///
pub fn writeString(str: []const u8) TtyError!void {
    // Make sure we update the cursor to the last character
    defer updateCursor();
    for (str) |char| {
        try putChar(char);
    }
}

///
/// Move up a page. This will copy the page above to the video buffer. Will keep trace of which
/// page is being displayed.
///
pub fn pageUp() void {
    if (page_index < TOTAL_NUM_PAGES - 1) {
        // Copy page to display
        page_index += 1;
        // Bounds have been checked, so shouldn't error
        videoCopy(START_OF_DISPLAYABLE_REGION, pages[page_index][0..TOTAL_CHAR_ON_PAGE], TOTAL_CHAR_ON_PAGE) catch |e| {
            log.crit("Error moving page up. Error: {}\n", .{e});
        };
        vga.disableCursor();
    }
}

///
/// Move down a page. This will copy the page bellow to the video buffer. Will keep trace of which
/// page is being displayed.
///
pub fn pageDown() void {
    if (page_index > 0) {
        // Copy page to display
        page_index -= 1;
        // Bounds have been checked, so shouldn't error
        videoCopy(START_OF_DISPLAYABLE_REGION, pages[page_index][0..TOTAL_CHAR_ON_PAGE], TOTAL_CHAR_ON_PAGE) catch |e| {
            log.crit("Error moving page down. Error: {}\n", .{e});
        };

        if (page_index == 0) {
            vga.enableCursor();
            updateCursor();
        } else {
            vga.disableCursor();
        }
    }
}

///
/// This clears the entire screen with blanks using the current colour. This will also save the
/// screen to the pages so can scroll back down.
///
pub fn clearScreen() void {
    // Move all the rows up
    // This is within bounds, so shouldn't error
    pagesMoveRowsUp(ROW_TOTAL) catch |e| {
        log.crit("Error moving all pages up. Error: {}\n", .{e});
    };

    // Clear the screen
    var i: u16 = START_OF_DISPLAYABLE_REGION;
    while (i < VIDEO_BUFFER_SIZE) : (i += 1) {
        video_buffer[i] = blank;
    }

    // Set the cursor to below the logo
    column = 0;
    row = ROW_MIN;
    updateCursor();
}

///
/// This moves the software and hardware cursor to the left by one.
///
pub fn moveCursorLeft() void {
    if (column == 0) {
        if (row != 0) {
            column = vga.WIDTH - 1;
            row -= 1;
        }
    } else {
        column -= 1;
    }

    updateCursor();
}

///
/// This moves the software and hardware cursor to the right by one.
///
pub fn moveCursorRight() void {
    if (column == (vga.WIDTH - 1)) {
        if (row != (vga.HEIGHT - 1)) {
            column = 0;
            row += 1;
        }
    } else {
        column += 1;
    }

    updateCursor();
}

///
/// This will set a new colour for the screen. It will only become effective when printing new
/// characters. Use vga.colourEntry and the colour enums to set the colour.
///
/// Arguments:
///     IN new_colour: u8 - The new foreground and background colour of the screen.
///
pub fn setColour(new_colour: u8) void {
    colour = new_colour;
    blank = vga.entry(0, colour);
}

///
/// Gets the video buffer's virtual address.
///
/// Return: usize
///     The virtual address of the video buffer
///
pub fn getVideoBufferAddress() usize {
    return @ptrToInt(&KERNEL_ADDR_OFFSET) + 0xB8000;
}

///
/// Initialise the tty. This will keep the bootloaders output and set the software cursor to where
/// the bootloader left it. Will copy the current screen to the pages, set the colour and blank
/// entry, print the logo and display the 0'th page.
///
pub fn init() void {
    // Video buffer in higher half
    if (is_test) {
        video_buffer = @intToPtr([*]volatile u16, mock_getVideoBufferAddress())[0..VIDEO_BUFFER_SIZE];
    } else {
        video_buffer = @intToPtr([*]volatile u16, getVideoBufferAddress())[0..VIDEO_BUFFER_SIZE];
    }

    setColour(vga.entryColour(vga.COLOUR_LIGHT_GREY, vga.COLOUR_BLACK));

    // Enable and get the hardware cursor to set the software cursor
    vga.enableCursor();
    getCursor();

    if (row != 0 or column != 0) {
        // Copy rows 7 down to make room for logo
        // If there isn't enough room, only take the bottom rows
        var row_offset: u16 = 0;
        if (vga.HEIGHT - 1 - row < ROW_MIN) {
            row_offset = ROW_MIN - (vga.HEIGHT - 1 - row);
        }

        // Make a copy into the pages
        // Assuming that there is only one page
        var i: u16 = 0;
        while (i < row * vga.WIDTH) : (i += 1) {
            pages[0][i] = video_buffer[i];
        }

        // Move 7 rows down
        i = 0;
        if (@ptrToInt(&video_buffer[ROW_MIN * vga.WIDTH]) < @ptrToInt(&video_buffer[row_offset * vga.WIDTH])) {
            while (i != row * vga.WIDTH) : (i += 1) {
                video_buffer[i + (ROW_MIN * vga.WIDTH)] = video_buffer[i + (row_offset * vga.WIDTH)];
            }
        } else {
            i = row * vga.WIDTH;
            while (i != 0) {
                i -= 1;
                video_buffer[i + (ROW_MIN * vga.WIDTH)] = video_buffer[i + (row_offset * vga.WIDTH)];
            }
        }

        // Set the top 7 rows blank
        setVideoBuffer(blank, START_OF_DISPLAYABLE_REGION) catch |e| {
            log.crit("Error clearing the top 7 rows. Error: {}\n", .{e});
        };
        row += @truncate(u8, row_offset + ROW_MIN);
    } else {
        // Clear the screen
        setVideoBuffer(blank, VIDEO_BUFFER_SIZE) catch |e| {
            log.crit("Error clearing the screen. Error: {}\n", .{e});
        };
        // Set the row to below the logo
        row = ROW_MIN;
    }

    switch (build_options.test_mode) {
        .Initialisation => runtimeTests(),
        else => {},
    }
}

const test_colour: u8 = vga.orig_entryColour(vga.COLOUR_LIGHT_GREY, vga.COLOUR_BLACK);
var test_video_buffer: [VIDEO_BUFFER_SIZE]u16 = [_]u16{0} ** VIDEO_BUFFER_SIZE;

fn mock_getVideoBufferAddress() usize {
    return @ptrToInt(&test_video_buffer);
}

fn resetGlobals() void {
    column = 0;
    row = 0;
    page_index = 0;
    colour = undefined;
    video_buffer = undefined;
    blank = undefined;

    pages = init: {
        var p: [TOTAL_NUM_PAGES][TOTAL_CHAR_ON_PAGE]u16 = undefined;

        for (p) |*page| {
            page.* = [_]u16{0} ** TOTAL_CHAR_ON_PAGE;
        }

        break :init p;
    };
}

fn setUpVideoBuffer() !void {
    // Change to a stack location
    video_buffer = test_video_buffer[0..VIDEO_BUFFER_SIZE];

    try expectEqual(@ptrToInt(video_buffer.ptr), @ptrToInt(&test_video_buffer[0]));

    colour = test_colour;
    blank = vga.orig_entry(0, test_colour);
}

fn setVideoBufferBlankPages() !void {
    try setUpVideoBuffer();
    for (video_buffer) |*b| {
        b.* = blank;
    }

    setPagesBlank();
}

fn setVideoBufferIncrementingBlankPages() !void {
    try setUpVideoBuffer();
    for (video_buffer) |*b, i| {
        b.* = @intCast(u16, i);
    }

    setPagesBlank();
}

fn setPagesBlank() void {
    for (pages) |*p_i| {
        for (p_i) |*p_j| {
            p_j.* = blank;
        }
    }
}

fn setPagesIncrementing() void {
    for (pages) |*p_i, i| {
        for (p_i) |*p_j, j| {
            p_j.* = @intCast(u16, i) * TOTAL_CHAR_ON_PAGE + @intCast(u16, j);
        }
    }
}

fn defaultVariablesTesting(p_i: u8, r: u8, c: u8) !void {
    try expectEqual(test_colour, colour);
    try expectEqual(@as(u16, test_colour) << 8, blank);
    try expectEqual(p_i, page_index);
    try expectEqual(r, row);
    try expectEqual(c, column);
}

fn incrementingPagesTesting() !void {
    for (pages) |p_i, i| {
        for (p_i) |p_j, j| {
            try expectEqual(i * TOTAL_CHAR_ON_PAGE + j, p_j);
        }
    }
}

fn blankPagesTesting() !void {
    for (pages) |p_i| {
        for (p_i) |p_j| {
            try expectEqual(blank, p_j);
        }
    }
}

fn incrementingVideoBufferTesting() !void {
    var i: u32 = 0;
    while (i < VIDEO_BUFFER_SIZE) : (i += 1) {
        const b = video_buffer[i];
        try expectEqual(i, b);
    }
}

fn defaultVideoBufferTesting() !void {
    var i: u32 = 0;
    while (i < VIDEO_BUFFER_SIZE) : (i += 1) {
        const b = video_buffer[i];
        try expectEqual(vga.orig_entry(0, test_colour), b);
    }
}

fn defaultAllTesting(p_i: u8, r: u8, c: u8) !void {
    try defaultVariablesTesting(p_i, r, c);
    try blankPagesTesting();
    try defaultVideoBufferTesting();
}

test "updateCursor" {
    // Set up
    try setVideoBufferBlankPages();

    // Mocking out the vga.updateCursor call for updating the hardware cursor
    vga.initTest();
    defer vga.freeTest();

    vga.addTestParams("updateCursor", .{ @as(u16, 0), @as(u16, 0) });

    // Pre testing
    try defaultAllTesting(0, 0, 0);

    // Call function
    updateCursor();

    // Post test
    try defaultAllTesting(0, 0, 0);

    // Tear down
    resetGlobals();
}

test "getCursor zero" {
    // Set up
    try setVideoBufferBlankPages();

    // Mocking out the vga.getCursor call for getting the hardware cursor
    vga.initTest();
    defer vga.freeTest();

    vga.addTestParams("getCursor", .{@as(u16, 0)});

    // Pre testing
    try defaultAllTesting(0, 0, 0);

    // Call function
    getCursor();

    // Post test
    try defaultAllTesting(0, 0, 0);

    // Tear down
    resetGlobals();
}

test "getCursor EEF" {
    // Set up
    try setVideoBufferBlankPages();

    // Mocking out the vga.getCursor call for getting the hardware cursor
    vga.initTest();
    defer vga.freeTest();

    vga.addTestParams("getCursor", .{@as(u16, 0x0EEF)});

    // Pre testing
    try defaultAllTesting(0, 0, 0);

    // Call function
    getCursor();

    // Post test
    try defaultAllTesting(0, 47, 63);

    // Tear down
    resetGlobals();
}

test "putEntryAt out of bounds" {
    // Set up
    try setVideoBufferBlankPages();

    // Pre testing
    try defaultAllTesting(0, 0, 0);

    // Call function
    try expectError(TtyError.OutOfBounds, putEntryAt('A', 100, 100));

    // Post test
    try defaultAllTesting(0, 0, 0);

    // Tear down
    resetGlobals();
}

test "putEntryAt not in displayable region" {
    // Set up
    try setVideoBufferBlankPages();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("entry", vga.orig_entry);
    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    // Enable and update cursor is only called once, can can use the consume function call
    //vga.addConsumeFunction("enableCursor", vga.mock_enableCursor);

    // Pre testing
    try defaultAllTesting(0, 0, 0);

    // Call function
    const x = 0;
    const y = 0;
    const char = 'A';
    try putEntryAt(char, x, y);

    // Post test
    try defaultVariablesTesting(0, 0, 0);
    try blankPagesTesting();

    var i: u32 = 0;
    while (i < VIDEO_BUFFER_SIZE) : (i += 1) {
        const b = video_buffer[i];
        if (i == y * vga.WIDTH + x) {
            try expectEqual(vga.orig_entry(char, test_colour), b);
        } else {
            try expectEqual(vga.orig_entry(0, test_colour), b);
        }
    }

    // Tear down
    resetGlobals();
}

test "putEntryAt in displayable region page_index is 0" {
    // Set up
    try setVideoBufferBlankPages();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("entry", vga.orig_entry);
    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    // Pre testing
    try defaultAllTesting(0, 0, 0);

    // Call function
    const x = 0;
    const y = ROW_MIN;
    const char = 'A';
    try putEntryAt(char, x, y);

    // Post test
    try defaultVariablesTesting(0, 0, 0);
    for (pages) |page, i| {
        for (page) |c, j| {
            if (i == page_index and (j == (y * vga.WIDTH + x) - START_OF_DISPLAYABLE_REGION)) {
                try expectEqual(vga.orig_entry(char, test_colour), c);
            } else {
                try expectEqual(blank, c);
            }
        }
    }

    var i: u32 = 0;
    while (i < VIDEO_BUFFER_SIZE) : (i += 1) {
        const b = video_buffer[i];
        if (i == y * vga.WIDTH + x) {
            try expectEqual(vga.orig_entry(char, test_colour), b);
        } else {
            try expectEqual(vga.orig_entry(0, test_colour), b);
        }
    }

    // Tear down
    resetGlobals();
}

test "putEntryAt in displayable region page_index is not 0" {
    // Set up
    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("entry", vga.orig_entry);
    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    // Enable and update cursor is only called once, can can use the consume function call
    vga.addConsumeFunction("enableCursor", vga.mock_enableCursor);

    try setVideoBufferBlankPages();

    // Fill the 1'nd page (index 1) will all 1's
    const ones = vga.orig_entry('1', test_colour);
    for (pages) |*page, i| {
        for (page) |*char| {
            if (i == 0) {
                char.* = ones;
            } else {
                char.* = 0;
            }
        }
    }

    page_index = 1;

    // Pre testing
    try defaultVariablesTesting(1, 0, 0);
    try defaultVideoBufferTesting();

    for (pages) |page, i| {
        for (page) |char| {
            if (i == 0) {
                try expectEqual(ones, char);
            } else {
                try expectEqual(@as(u16, 0), char);
            }
        }
    }

    // Call function
    const x = 0;
    const y = ROW_MIN;
    const char = 'A';
    try putEntryAt(char, x, y);

    // Post test
    try defaultVariablesTesting(0, 0, 0);

    // Print page number
    const text = "Page 0 of 4";
    const column_temp = column;
    const row_temp = row;
    column = @truncate(u8, vga.WIDTH) - @truncate(u8, text.len);
    row = ROW_MIN - 1;
    writeString(text) catch |e| {
        log.crit("Unable to print page number, printing out of bounds. Error: {}\n", .{e});
    };
    column = column_temp;
    row = row_temp;

    for (pages) |page, i| {
        for (page) |c, j| {
            if (i == 0 and j == 0) {
                try expectEqual(vga.orig_entry(char, test_colour), c);
            } else if (i == 0) {
                try expectEqual(ones, c);
            } else {
                try expectEqual(@as(u16, 0), c);
            }
        }
    }

    // The top 7 rows won't be copied
    var i: u32 = 0;
    while (i < VIDEO_BUFFER_SIZE) : (i += 1) {
        const b = video_buffer[i];
        if (i < START_OF_DISPLAYABLE_REGION - 11) {
            try expectEqual(blank, b);
        } else if (i < START_OF_DISPLAYABLE_REGION) {
            try expectEqual(vga.orig_entry(text[i + 11 - START_OF_DISPLAYABLE_REGION], colour), b);
        } else if (i == y * vga.WIDTH + x) {
            try expectEqual(vga.orig_entry(char, test_colour), b);
        } else {
            try expectEqual(ones, b);
        }
    }

    // Tear down
    resetGlobals();
}

test "pagesMoveRowsUp out of bounds" {
    // Set up
    try setVideoBufferBlankPages();
    setPagesIncrementing();

    // Pre testing
    try defaultVariablesTesting(0, 0, 0);
    try defaultVideoBufferTesting();
    try incrementingPagesTesting();

    // Call function
    const rows_to_move = ROW_TOTAL + 1;
    try expectError(TtyError.OutOfBounds, pagesMoveRowsUp(rows_to_move));

    // Post test
    try defaultVariablesTesting(0, 0, 0);
    try defaultVideoBufferTesting();
    try incrementingPagesTesting();

    // Tear down
    resetGlobals();
}

test "pagesMoveRowsUp 0 rows" {
    // Set up
    try setVideoBufferBlankPages();
    setPagesIncrementing();

    // Pre testing
    try defaultVariablesTesting(0, 0, 0);
    try defaultVideoBufferTesting();
    try incrementingPagesTesting();

    // Call function
    const rows_to_move = 0;
    try pagesMoveRowsUp(rows_to_move);

    // Post test
    try defaultVariablesTesting(0, 0, 0);
    try defaultVideoBufferTesting();
    try incrementingPagesTesting();

    // Tear down
    resetGlobals();
}

test "pagesMoveRowsUp 1 rows" {
    // Set up
    try setVideoBufferBlankPages();
    setPagesIncrementing();

    // Pre testing
    try defaultVariablesTesting(0, 0, 0);
    try defaultVideoBufferTesting();
    try incrementingPagesTesting();

    // Call function
    const rows_to_move = 1;
    try pagesMoveRowsUp(rows_to_move);

    // Post test
    try defaultVariablesTesting(0, 0, 0);
    try defaultVideoBufferTesting();

    const to_add = rows_to_move * vga.WIDTH;
    for (pages) |page, i| {
        for (page) |c, j| {
            if (j >= TOTAL_CHAR_ON_PAGE - to_add) {
                if (i == 0) {
                    // The last rows will be blanks
                    try expectEqual(blank, c);
                } else {
                    try expectEqual((i - 1) * TOTAL_CHAR_ON_PAGE + (j + to_add - TOTAL_CHAR_ON_PAGE), c);
                }
            } else {
                // All rows moved up one, so add vga.WIDTH
                try expectEqual(i * TOTAL_CHAR_ON_PAGE + j + to_add, c);
            }
        }
    }

    // Tear down
    resetGlobals();
}

test "pagesMoveRowsUp ROW_TOTAL - 1 rows" {
    // Set up
    try setVideoBufferBlankPages();
    setPagesIncrementing();

    // Pre testing
    try defaultVariablesTesting(0, 0, 0);
    try defaultVideoBufferTesting();
    try incrementingPagesTesting();

    // Call function
    const rows_to_move = ROW_TOTAL - 1;
    try pagesMoveRowsUp(rows_to_move);

    // Post test
    try defaultVariablesTesting(0, 0, 0);
    try defaultVideoBufferTesting();

    const to_add = rows_to_move * vga.WIDTH;
    for (pages) |page, i| {
        for (page) |c, j| {
            if (j >= TOTAL_CHAR_ON_PAGE - to_add) {
                if (i == 0) {
                    // The last rows will be blanks
                    try expectEqual(blank, c);
                } else {
                    try expectEqual((i - 1) * TOTAL_CHAR_ON_PAGE + (j + to_add - TOTAL_CHAR_ON_PAGE), c);
                }
            } else {
                // All rows moved up one, so add vga.WIDTH
                try expectEqual(i * TOTAL_CHAR_ON_PAGE + j + to_add, c);
            }
        }
    }

    // Tear down
    resetGlobals();
}

test "pagesMoveRowsUp ROW_TOTAL rows" {
    // Set up
    try setVideoBufferBlankPages();
    setPagesIncrementing();

    // Pre testing
    try defaultVariablesTesting(0, 0, 0);
    try defaultVideoBufferTesting();
    try incrementingPagesTesting();

    // Call function
    const rows_to_move = ROW_TOTAL;
    try pagesMoveRowsUp(rows_to_move);

    // Post test
    try defaultVariablesTesting(0, 0, 0);
    try defaultVideoBufferTesting();

    for (pages) |page, i| {
        for (page) |c, j| {
            if (i == 0) {
                // The last rows will be blanks
                try expectEqual(blank, c);
            } else {
                try expectEqual((i - 1) * TOTAL_CHAR_ON_PAGE + j, c);
            }
        }
    }

    // Tear down
    resetGlobals();
}

test "scroll row is less then max height" {
    // Set up
    try setVideoBufferBlankPages();
    setPagesIncrementing();

    // Pre testing
    try defaultVariablesTesting(0, 0, 0);
    try defaultVideoBufferTesting();
    try incrementingPagesTesting();

    // Call function
    scroll();

    // Post test
    try defaultVariablesTesting(0, 0, 0);
    try defaultVideoBufferTesting();
    try incrementingPagesTesting();

    // Tear down
    resetGlobals();
}

test "scroll row is equal to height" {
    // Set up
    try setVideoBufferIncrementingBlankPages();
    setPagesIncrementing();

    const row_test = vga.HEIGHT;
    row = row_test;

    // Pre testing
    try defaultVariablesTesting(0, row_test, 0);
    try incrementingPagesTesting();
    try incrementingVideoBufferTesting();

    // Call function
    // Rows move up one
    scroll();

    // Post test
    try defaultVariablesTesting(0, vga.HEIGHT - 1, 0);

    const to_add = (row_test - vga.HEIGHT + 1) * vga.WIDTH;
    for (pages) |page, i| {
        for (page) |c, j| {
            if (j >= TOTAL_CHAR_ON_PAGE - to_add) {
                if (i == 0) {
                    // The last rows will be blanks
                    try expectEqual(blank, c);
                } else {
                    try expectEqual((i - 1) * TOTAL_CHAR_ON_PAGE + (j + to_add - TOTAL_CHAR_ON_PAGE), c);
                }
            } else {
                // All rows moved up one, so add vga.WIDTH
                try expectEqual(i * TOTAL_CHAR_ON_PAGE + j + to_add, c);
            }
        }
    }

    var i: u32 = 0;
    while (i < VIDEO_BUFFER_SIZE) : (i += 1) {
        const buf = video_buffer[i];
        if (i < START_OF_DISPLAYABLE_REGION) {
            try expectEqual(i, buf);
        } else if (i >= VIDEO_BUFFER_SIZE - to_add) {
            try expectEqual(blank, buf);
        } else {
            try expectEqual(i + to_add, buf);
        }
    }

    // Tear down
    resetGlobals();
}

test "scroll row is more than height" {
    // Set up
    try setVideoBufferIncrementingBlankPages();
    setPagesIncrementing();

    const row_test = vga.HEIGHT + 5;
    row = row_test;

    // Pre testing
    try defaultVariablesTesting(0, row_test, 0);
    try incrementingPagesTesting();
    try incrementingVideoBufferTesting();

    // Call function
    // Rows move up 5
    scroll();

    // Post test
    try defaultVariablesTesting(0, vga.HEIGHT - 1, 0);

    const to_add = (row_test - vga.HEIGHT + 1) * vga.WIDTH;
    for (pages) |page, i| {
        for (page) |c, j| {
            if (j >= TOTAL_CHAR_ON_PAGE - to_add) {
                if (i == 0) {
                    // The last rows will be blanks
                    try expectEqual(blank, c);
                } else {
                    try expectEqual((i - 1) * TOTAL_CHAR_ON_PAGE + (j + to_add - TOTAL_CHAR_ON_PAGE), c);
                }
            } else {
                // All rows moved up one, so add vga.WIDTH
                try expectEqual(i * TOTAL_CHAR_ON_PAGE + j + to_add, c);
            }
        }
    }

    var i: u32 = 0;
    while (i < VIDEO_BUFFER_SIZE) : (i += 1) {
        const buf = video_buffer[i];
        if (i < START_OF_DISPLAYABLE_REGION) {
            try expectEqual(i, buf);
        } else if (i >= VIDEO_BUFFER_SIZE - to_add) {
            try expectEqual(blank, buf);
        } else {
            try expectEqual(i + to_add, buf);
        }
    }

    // Tear down
    resetGlobals();
}

test "putChar new line within screen" {
    // Set up
    try setVideoBufferBlankPages();

    // Pre testing
    column = 5;
    row = 5;
    try defaultAllTesting(0, 5, 5);

    // Call function
    try putChar('\n');

    // Post test
    try defaultAllTesting(0, 6, 0);

    // Tear down
    resetGlobals();
}

test "putChar new line outside screen" {
    // Set up
    try setVideoBufferBlankPages();

    // Pre testing
    column = 5;
    row = vga.HEIGHT - 1;
    try defaultAllTesting(0, vga.HEIGHT - 1, 5);

    // Call function
    try putChar('\n');

    // Post test
    try defaultAllTesting(0, vga.HEIGHT - 1, 0);

    // Tear down
    resetGlobals();
}

test "putChar tab within line" {
    // Set up
    try setVideoBufferBlankPages();

    // Pre testing
    column = 5;
    row = 6;
    try defaultAllTesting(0, 6, 5);

    // Call function
    try putChar('\t');

    // Post test
    try defaultAllTesting(0, 6, 9);

    // Tear down
    resetGlobals();
}

test "putChar tab end of line" {
    // Set up
    try setVideoBufferBlankPages();

    // Pre testing
    column = vga.WIDTH - 1;
    row = 6;
    try defaultAllTesting(0, 6, vga.WIDTH - 1);

    // Call function
    try putChar('\t');

    // Post test
    try defaultAllTesting(0, 7, 3);

    // Tear down
    resetGlobals();
}

test "putChar tab end of screen" {
    // Set up
    try setVideoBufferBlankPages();

    // Pre testing
    column = vga.WIDTH - 1;
    row = vga.HEIGHT - 1;
    try defaultAllTesting(0, vga.HEIGHT - 1, vga.WIDTH - 1);

    // Call function
    try putChar('\t');

    // Post test
    try defaultAllTesting(0, vga.HEIGHT - 1, 3);

    // Tear down
    resetGlobals();
}

test "putChar line feed" {
    // Set up
    try setVideoBufferBlankPages();

    // Pre testing
    column = vga.WIDTH - 1;
    row = vga.HEIGHT - 1;
    try defaultAllTesting(0, vga.HEIGHT - 1, vga.WIDTH - 1);

    // Call function
    try putChar('\r');

    // Post test
    try defaultAllTesting(0, vga.HEIGHT - 1, 0);

    // Tear down
    resetGlobals();
}

test "putChar back char top left of screen" {
    // Set up
    try setVideoBufferBlankPages();

    // Pre testing
    try defaultAllTesting(0, 0, 0);

    // Call function
    try putChar('\x08');

    // Post test
    try defaultAllTesting(0, 0, 0);

    // Tear down
    resetGlobals();
}

test "putChar back char top row" {
    // Set up
    try setVideoBufferBlankPages();

    // Pre testing
    column = 8;
    try defaultAllTesting(0, 0, 8);

    // Call function
    try putChar('\x08');

    // Post test
    try defaultAllTesting(0, 0, 7);

    // Tear down
    resetGlobals();
}

test "putChar back char beginning of row" {
    // Set up
    try setVideoBufferBlankPages();

    // Pre testing
    row = 1;
    try defaultAllTesting(0, 1, 0);

    // Call function
    try putChar('\x08');

    // Post test
    try defaultAllTesting(0, 0, vga.WIDTH - 1);

    // Tear down
    resetGlobals();
}

test "putChar any char in row" {
    // Set up
    try setVideoBufferBlankPages();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("entry", vga.orig_entry);

    // Pre testing
    try defaultAllTesting(0, 0, 0);

    // Call function
    try putChar('A');

    // Post test
    try defaultVariablesTesting(0, 0, 1);
    try blankPagesTesting();

    var i: u32 = 0;
    while (i < VIDEO_BUFFER_SIZE) : (i += 1) {
        const buf = video_buffer[i];
        if (i == 0) {
            try expectEqual(vga.orig_entry('A', colour), buf);
        } else {
            try expectEqual(blank, buf);
        }
    }

    // Tear down
    resetGlobals();
}

test "putChar any char end of row" {
    // Set up
    try setVideoBufferBlankPages();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("entry", vga.orig_entry);

    // Pre testing
    column = vga.WIDTH - 1;
    try defaultAllTesting(0, 0, vga.WIDTH - 1);

    // Call function
    try putChar('A');

    // Post test
    try defaultVariablesTesting(0, 1, 0);
    try blankPagesTesting();

    var i: u32 = 0;
    while (i < VIDEO_BUFFER_SIZE) : (i += 1) {
        const buf = video_buffer[i];
        if (i == vga.WIDTH - 1) {
            try expectEqual(vga.orig_entry('A', colour), buf);
        } else {
            try expectEqual(blank, buf);
        }
    }

    // Tear down
    resetGlobals();
}

test "putChar any char end of screen" {
    // Set up
    try setVideoBufferBlankPages();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("entry", vga.orig_entry);

    // Pre testing
    row = vga.HEIGHT - 1;
    column = vga.WIDTH - 1;
    try defaultAllTesting(0, vga.HEIGHT - 1, vga.WIDTH - 1);

    // Call function
    try putChar('A');

    // Post test
    try defaultVariablesTesting(0, vga.HEIGHT - 1, 0);
    for (pages) |page, i| {
        for (page) |c, j| {
            if ((i == 0) and (j == TOTAL_CHAR_ON_PAGE - vga.WIDTH - 1)) {
                try expectEqual(vga.orig_entry('A', colour), c);
            } else {
                try expectEqual(blank, c);
            }
        }
    }

    var i: u32 = 0;
    while (i < VIDEO_BUFFER_SIZE) : (i += 1) {
        const buf = video_buffer[i];
        if (i == VIDEO_BUFFER_SIZE - vga.WIDTH - 1) {
            try expectEqual(vga.orig_entry('A', colour), buf);
        } else {
            try expectEqual(blank, buf);
        }
    }

    // Tear down
    resetGlobals();
}

test "pageUp top page" {
    // Set up
    try setVideoBufferBlankPages();
    setPagesIncrementing();

    // Pre testing
    page_index = TOTAL_NUM_PAGES - 1;

    try defaultVariablesTesting(TOTAL_NUM_PAGES - 1, 0, 0);
    try incrementingPagesTesting();
    try defaultVideoBufferTesting();

    // Call function
    pageUp();

    // Post test
    try defaultVariablesTesting(TOTAL_NUM_PAGES - 1, 0, 0);
    try incrementingPagesTesting();
    try defaultVideoBufferTesting();

    // Tear down
    resetGlobals();
}

test "pageUp bottom page" {
    // Set up
    try setVideoBufferBlankPages();
    setPagesIncrementing();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("entry", vga.orig_entry);
    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    vga.addConsumeFunction("disableCursor", vga.mock_disableCursor);

    // Pre testing
    try defaultVariablesTesting(0, 0, 0);
    try incrementingPagesTesting();
    try defaultVideoBufferTesting();

    // Call function
    pageUp();

    // Post test
    try defaultVariablesTesting(1, 0, 0);
    try incrementingPagesTesting();

    // Print page number
    const text = "Page 1 of 4";
    const column_temp = column;
    const row_temp = row;
    column = @truncate(u8, vga.WIDTH) - @truncate(u8, text.len);
    row = ROW_MIN - 1;
    writeString(text) catch |e| {
        log.crit("Unable to print page number, printing out of bounds. Error: {}\n", .{e});
    };
    column = column_temp;
    row = row_temp;

    var i: u32 = 0;
    while (i < VIDEO_BUFFER_SIZE) : (i += 1) {
        const b = video_buffer[i];
        // Ignore the ROW_MIN row as this is where the page number is printed and is already
        // tested, page number is printed 11 from the end
        if (i < START_OF_DISPLAYABLE_REGION - 11) {
            try expectEqual(blank, b);
        } else if (i < START_OF_DISPLAYABLE_REGION) {
            try expectEqual(vga.orig_entry(text[i + 11 - START_OF_DISPLAYABLE_REGION], colour), b);
        } else {
            try expectEqual(i - START_OF_DISPLAYABLE_REGION + TOTAL_CHAR_ON_PAGE, b);
        }
    }

    // Tear down
    resetGlobals();
}

test "pageDown bottom page" {
    // Set up
    try setVideoBufferBlankPages();
    setPagesIncrementing();

    // Pre testing
    try defaultVariablesTesting(0, 0, 0);
    try incrementingPagesTesting();
    try defaultVideoBufferTesting();

    // Call function
    pageDown();

    // Post test
    try defaultVariablesTesting(0, 0, 0);
    try incrementingPagesTesting();
    try defaultVideoBufferTesting();

    // Tear down
    resetGlobals();
}

test "pageDown top page" {
    // Set up
    try setVideoBufferBlankPages();
    setPagesIncrementing();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("entry", vga.orig_entry);
    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    vga.addConsumeFunction("disableCursor", vga.mock_disableCursor);

    // Pre testing
    page_index = TOTAL_NUM_PAGES - 1;

    try defaultVariablesTesting(TOTAL_NUM_PAGES - 1, 0, 0);
    try incrementingPagesTesting();
    try defaultVideoBufferTesting();

    // Call function
    pageDown();

    // Post test
    try defaultVariablesTesting(TOTAL_NUM_PAGES - 2, 0, 0);
    try incrementingPagesTesting();

    // Print page number
    const text = "Page 3 of 4";
    const column_temp = column;
    const row_temp = row;
    column = @truncate(u8, vga.WIDTH) - @truncate(u8, text.len);
    row = ROW_MIN - 1;
    writeString(text) catch |e| {
        log.crit("Unable to print page number, printing out of bounds. Error: {}\n", .{e});
    };
    column = column_temp;
    row = row_temp;

    var i: u32 = 0;
    while (i < VIDEO_BUFFER_SIZE) : (i += 1) {
        const b = video_buffer[i];
        // Ignore the ROW_MIN row as this is where the page number is printed and is already
        // tested, page number is printed 11 from the end
        if (i < START_OF_DISPLAYABLE_REGION - 11) {
            try expectEqual(blank, b);
        } else if (i < START_OF_DISPLAYABLE_REGION) {
            try expectEqual(vga.orig_entry(text[i + 11 - START_OF_DISPLAYABLE_REGION], colour), b);
        } else {
            try expectEqual((i - START_OF_DISPLAYABLE_REGION) + (TOTAL_CHAR_ON_PAGE * page_index), b);
        }
    }

    // Tear down
    resetGlobals();
}

test "clearScreen" {
    // Set up
    try setVideoBufferIncrementingBlankPages();
    setPagesIncrementing();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    // Pre testing
    try defaultVariablesTesting(0, 0, 0);
    try incrementingVideoBufferTesting();
    try incrementingPagesTesting();

    // Call function
    clearScreen();

    // Post test
    try defaultVariablesTesting(0, ROW_MIN, 0);
    var i: u32 = 0;
    while (i < VIDEO_BUFFER_SIZE) : (i += 1) {
        const buf = video_buffer[i];
        if (i < START_OF_DISPLAYABLE_REGION) {
            try expectEqual(i, buf);
        } else {
            try expectEqual(blank, buf);
        }
    }

    for (pages) |page, j| {
        for (page) |c, k| {
            if (j == 0) {
                // The last rows will be blanks
                try expectEqual(blank, c);
            } else {
                try expectEqual((j - 1) * TOTAL_CHAR_ON_PAGE + k, c);
            }
        }
    }

    // Tear down
    resetGlobals();
}

test "moveCursorLeft top left of screen" {
    // Set up
    try setVideoBufferBlankPages();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    // Pre testing
    try defaultAllTesting(0, 0, 0);

    // Call function
    moveCursorLeft();

    // Post test
    try defaultAllTesting(0, 0, 0);

    // Tear down
    resetGlobals();
}

test "moveCursorLeft top screen" {
    // Set up
    try setVideoBufferBlankPages();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    // Pre testing
    column = 5;
    try defaultAllTesting(0, 0, 5);

    // Call function
    moveCursorLeft();

    // Post test
    try defaultAllTesting(0, 0, 4);

    // Tear down
    resetGlobals();
}

test "moveCursorLeft start of row" {
    // Set up
    try setVideoBufferBlankPages();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    // Pre testing
    row = 5;
    try defaultAllTesting(0, 5, 0);

    // Call function
    moveCursorLeft();

    // Post test
    try defaultAllTesting(0, 4, vga.WIDTH - 1);

    // Tear down
    resetGlobals();
}

test "moveCursorRight bottom right of screen" {
    // Set up
    try setVideoBufferBlankPages();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    // Pre testing
    row = vga.HEIGHT - 1;
    column = vga.WIDTH - 1;
    try defaultAllTesting(0, vga.HEIGHT - 1, vga.WIDTH - 1);

    // Call function
    moveCursorRight();

    // Post test
    try defaultAllTesting(0, vga.HEIGHT - 1, vga.WIDTH - 1);

    // Tear down
    resetGlobals();
}

test "moveCursorRight top screen" {
    // Set up
    try setVideoBufferBlankPages();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    // Pre testing
    column = 5;
    try defaultAllTesting(0, 0, 5);

    // Call function
    moveCursorRight();

    // Post test
    try defaultAllTesting(0, 0, 6);

    // Tear down
    resetGlobals();
}

test "moveCursorRight end of row" {
    // Set up
    try setVideoBufferBlankPages();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    // Pre testing
    row = 5;
    column = vga.WIDTH - 1;
    try defaultAllTesting(0, 5, vga.WIDTH - 1);

    // Call function
    moveCursorRight();

    // Post test
    try defaultAllTesting(0, 6, 0);

    // Tear down
    resetGlobals();
}

test "setColour" {
    // Set up
    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addConsumeFunction("entry", vga.orig_entry);

    // Pre testing

    // Call function
    const new_colour = vga.orig_entryColour(vga.COLOUR_WHITE, vga.COLOUR_WHITE);
    setColour(new_colour);

    // Post test
    try expectEqual(new_colour, colour);
    try expectEqual(vga.orig_entry(0, new_colour), blank);

    // Tear down
    resetGlobals();
}

test "writeString" {
    // Set up
    try setVideoBufferBlankPages();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("entry", vga.orig_entry);

    vga.addConsumeFunction("updateCursor", vga.mock_updateCursor);

    // Pre testing
    row = ROW_MIN;
    try defaultAllTesting(0, ROW_MIN, 0);

    // Call function
    try writeString("ABC");

    // Post test
    try defaultVariablesTesting(0, ROW_MIN, 3);
    for (pages) |page, i| {
        for (page) |c, j| {
            if ((i == 0) and (j == 0)) {
                try expectEqual(vga.orig_entry('A', colour), c);
            } else if ((i == 0) and (j == 1)) {
                try expectEqual(vga.orig_entry('B', colour), c);
            } else if ((i == 0) and (j == 2)) {
                try expectEqual(vga.orig_entry('C', colour), c);
            } else {
                try expectEqual(blank, c);
            }
        }
    }

    var i: u32 = 0;
    while (i < VIDEO_BUFFER_SIZE) : (i += 1) {
        const buf = video_buffer[i];
        if (i == START_OF_DISPLAYABLE_REGION) {
            try expectEqual(vga.orig_entry('A', colour), buf);
        } else if (i == START_OF_DISPLAYABLE_REGION + 1) {
            try expectEqual(vga.orig_entry('B', colour), buf);
        } else if (i == START_OF_DISPLAYABLE_REGION + 2) {
            try expectEqual(vga.orig_entry('C', colour), buf);
        } else {
            try expectEqual(blank, buf);
        }
    }

    // Tear down
    resetGlobals();
}

test "init 0,0" {
    // Set up
    try setVideoBufferBlankPages();

    // Mocking out the vga.updateCursor call for updating the hardware cursor
    vga.initTest();
    defer vga.freeTest();

    vga.addTestParams("getCursor", .{@as(u16, 0)});

    vga.addRepeatFunction("entryColour", vga.orig_entryColour);
    vga.addRepeatFunction("entry", vga.orig_entry);
    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    vga.addConsumeFunction("enableCursor", vga.mock_enableCursor);

    // Pre testing
    try defaultAllTesting(0, 0, 0);

    // Call function
    init();

    // Post test
    try defaultVariablesTesting(0, ROW_MIN, 0);
    try blankPagesTesting();

    var i: u32 = 0;
    while (i < VIDEO_BUFFER_SIZE) : (i += 1) {
        const buf = video_buffer[i];
        if (i < START_OF_DISPLAYABLE_REGION) {
            // This is where the logo will be, but is a complex string so no testing
            // Just take my word it works :P
        } else {
            try expectEqual(blank, buf);
        }
    }

    // Tear down
    resetGlobals();
}

test "init not 0,0" {
    // Set up
    try setVideoBufferBlankPages();

    // Mocking out the vga.updateCursor call for updating the hardware cursor
    vga.initTest();
    defer vga.freeTest();

    vga.addTestParams("getCursor", .{vga.WIDTH});

    vga.addRepeatFunction("entryColour", vga.orig_entryColour);
    vga.addRepeatFunction("entry", vga.orig_entry);
    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    vga.addConsumeFunction("enableCursor", vga.mock_enableCursor);

    // Pre testing
    try defaultAllTesting(0, 0, 0);

    // Call function
    init();

    // Post test
    try defaultVariablesTesting(0, ROW_MIN + 1, 0);
    try blankPagesTesting();

    var i: u32 = 0;
    while (i < VIDEO_BUFFER_SIZE) : (i += 1) {
        const buf = video_buffer[i];
        if (i < START_OF_DISPLAYABLE_REGION) {
            // This is where the logo will be, but is a complex string so no testing
            // Just take my word it works :P
        } else {
            try expectEqual(blank, buf);
        }
    }

    // Tear down
    resetGlobals();
}

///
/// Test the init function set up everything properly.
///
fn rt_initialisedGlobals() void {
    if (@ptrToInt(video_buffer.ptr) != @ptrToInt(&KERNEL_ADDR_OFFSET) + 0xB8000) {
        panic(@errorReturnTrace(), "Video buffer not at correct virtual address, found: {}\n", .{@ptrToInt(video_buffer.ptr)});
    }

    if (page_index != 0) {
        panic(@errorReturnTrace(), "Page index not at zero, found: {}\n", .{page_index});
    }

    if (colour != vga.entryColour(vga.COLOUR_LIGHT_GREY, vga.COLOUR_BLACK)) {
        panic(@errorReturnTrace(), "Colour not set up properly, found: {}\n", .{colour});
    }

    if (blank != vga.entry(0, colour)) {
        panic(@errorReturnTrace(), "Blank not set up properly, found: {}\n", .{blank});
    }

    // Make sure the screen isn't all blank
    var all_blank = true;
    var i: u32 = 0;
    while (i < VIDEO_BUFFER_SIZE) : (i += 1) {
        const buf = video_buffer[i];
        if (buf != blank and buf != 0) {
            all_blank = false;
            break;
        }
    }

    if (all_blank) {
        panic(@errorReturnTrace(), "Screen all blank, should have logo and page number\n", .{});
    }

    log.info("Tested globals\n", .{});
}

///
/// Test printing a string will output to the screen. This will check both the video memory and
/// the pages.
///
fn rt_printString() void {
    const text = "abcdefg";
    const clear_text = "\x08" ** text.len;

    writeString(text) catch |e| panic(@errorReturnTrace(), "Failed to print string to tty: {}\n", .{e});

    // Check the video memory
    var counter: u32 = 0;
    var i: u32 = 0;
    while (i < VIDEO_BUFFER_SIZE) : (i += 1) {
        const buf = video_buffer[i];
        if (counter < text.len and buf == vga.entry(text[counter], colour)) {
            counter += 1;
        } else if (counter == text.len) {
            // Found all the text
            break;
        } else {
            counter = 0;
        }
    }

    if (counter != text.len) {
        panic(@errorReturnTrace(), "Didn't find the printed text in video memory\n", .{});
    }

    // Check the pages
    counter = 0;
    for (pages[0]) |c| {
        if (counter < text.len and c == vga.entry(text[counter], colour)) {
            counter += 1;
        } else if (counter == text.len) {
            // Found all the text
            break;
        } else {
            counter = 0;
        }
    }

    if (counter != text.len) {
        panic(@errorReturnTrace(), "Didn't find the printed text in pages\n", .{});
    }

    // Clear the text
    writeString(clear_text) catch |e| panic(@errorReturnTrace(), "Failed to print string to tty: {}\n", .{e});

    log.info("Tested printing\n", .{});
}

///
/// Run all the runtime tests.
///
fn runtimeTests() void {
    rt_initialisedGlobals();
    rt_printString();
}

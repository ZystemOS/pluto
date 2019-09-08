const is_test = @import("builtin").is_test;

const std = @import("std");
const fmt = std.fmt;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

const vga = if (is_test) @import("mocking").vga else @import("vga.zig");
const log = if (is_test) @import("mocking").log else @import("log.zig");

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

/// The error set for if there is an error whiles printing.
const PrintError = error{OutOfBounds};

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
/// Errors:
///     PrintError.OutOfBounds - If offset or the size to copy is greater than the size of the
///                              video buffer or data to copy.
///
fn videoCopy(video_buf_offset: u16, data: []const u16, size: u16) PrintError!void {
    // Secure programming ;)
    if (video_buf_offset >= video_buffer.len and
        size > video_buffer.len - video_buf_offset and
        size > data.len)
    {
        return PrintError.OutOfBounds;
    }

    var i: usize = 0;
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
///     PrintError.OutOfBounds - If the size to copy is greater than the size of
///                              pages.
///
fn pageMove(dest: []u16, src: []u16, size: usize) PrintError!void {
    if (dest.len < size or src.len < size) {
        return PrintError.OutOfBounds;
    }

    // Not an error is size is zero, nothing will be copied
    if (size == 0) return;

    // Make sure we don't override the values we want to copy
    if (@ptrToInt(&dest[0]) < @ptrToInt(&src[0])) {
        var i: usize = 0;
        while (i != size) : (i += 1) {
            dest[i] = src[i];
        }
    } else {
        var i: usize = size;
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
fn setVideoBuffer(c: u16, size: u16) void {
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
/// Get the hardware cursor to set the current column and row (x, y).
///
fn getCursor() void {
    var cursor: u16 = vga.getCursor();

    row = @truncate(u8, cursor / vga.WIDTH);
    column = @truncate(u8, cursor % vga.WIDTH);
}

///
/// Display the current page number at the bottom right corner.
///
fn displayPageNumber() void {
    const column_temp: u8 = column;
    const row_temp: u8 = row;

    // A bit hard coded as the kprintf below is 11 characters long.
    // Once got a ksnprintf, then can use that value to set how far from the end to print.
    column = vga.WIDTH - 11;
    row = ROW_MIN - 1;

    print("Page {} of {}", page_index, TOTAL_NUM_PAGES - 1);

    column = column_temp;
    row = row_temp;
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
///     PrintError.OutOfBounds - If trying to print outside the video buffer
///
fn putEntryAt(char: u8, x: u8, y: u8) PrintError!void {
    const index: u16 = y * vga.WIDTH + x;

    // Bounds check
    if (index >= VIDEO_BUFFER_SIZE) {
        return PrintError.OutOfBounds;
    }

    const char_entry: u16 = vga.entry(char, colour);

    if (index >= START_OF_DISPLAYABLE_REGION) {
        // If not at page zero, (bottom of page), then display that page
        // The user has move up a number of pages and then typed a letter, so need to move to the
        // 0'th page
        if (page_index != 0) {
            // This isn't out of bounds
            page_index = 0;
            videoCopy(START_OF_DISPLAYABLE_REGION, pages[page_index][0..TOTAL_CHAR_ON_PAGE], TOTAL_CHAR_ON_PAGE) catch unreachable;
            displayPageNumber();

            // If not on page 0, then the cursor would have been disabled
            vga.enableCursor();
            updateCursor();
        }
        pages[page_index][index - START_OF_DISPLAYABLE_REGION] = char_entry;
    }
    video_buffer[index] = char_entry;
}

/// Move rows up pages across multiple pages leaving the last rows blank.
///
/// Arguments:
///     IN rows: u16 - The number of rows to move up.
///
/// Errors:
///     PrintError.OutOfBounds - If trying to move up more rows on a page
///
fn pagesMoveRowsUp(rows: u16) PrintError!void {
    // Out of bounds check, also no need to move 0 rows
    if (rows > ROW_TOTAL) {
        return PrintError.OutOfBounds;
    }

    // Not an error to move 0 rows, but is pointless
    if (rows == 0) return;

    // Move up rows in last page up by "rows"
    const row_length: u16 = rows * vga.WIDTH;
    const chars_to_move: u16 = (ROW_TOTAL - rows) * vga.WIDTH;
    pageMove(pages[TOTAL_NUM_PAGES - 1][0..chars_to_move], pages[TOTAL_NUM_PAGES - 1][row_length..], chars_to_move) catch unreachable;

    // Loop for the other pages
    var i = TOTAL_NUM_PAGES - 1;
    while (i > 0) : (i -= 1) {
        pageMove(pages[i][chars_to_move..], pages[i - 1][0..row_length], row_length) catch unreachable;
        pageMove(pages[i - 1][0..chars_to_move], pages[i - 1][row_length..], chars_to_move) catch unreachable;
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
fn scroll() void {
    // Added the condition in the if from pagesMoveRowsUp as don't need to move all rows
    if (row >= vga.HEIGHT and (row - vga.HEIGHT + 1) <= ROW_TOTAL) {
        var rows_to_move: u16 = row - vga.HEIGHT + 1;

        // Move rows up pages by temp, will usually be one.
        // Can't return an error
        pagesMoveRowsUp(rows_to_move) catch unreachable;

        // Move all rows up by rows_to_move
        var i: u16 = 0;
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
///     PrintError.OutOfBounds - If trying to scroll more rows on a page/displayable region or
///                              print beyond the video buffer.
///
fn putChar(char: u8) PrintError!void {
    const column_temp: u8 = column;
    const row_temp: u8 = row;

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
/// Print a string to the TTY. This also updates to hardware cursor.
///
/// Arguments:
///     IN str: []const u8 - The string to print.
///
/// Errors:
///     PrintError.OutOfBounds - If trying to print beyond the video buffer.
///
fn writeString(str: []const u8) PrintError!void {
    // Make sure we update the cursor to the last character
    defer updateCursor();
    for (str) |char| {
        try putChar(char);
    }
}

///
/// A call back function for use in the formation of a string. This calls writeString normally.
///
/// Arguments:
///     IN context: void      - The context of the printing. This will be empty.
///     IN string: []const u8 - The string to print.
///
/// Errors:
///     PrintError.OutOfBounds - If trying to print beyond the video buffer.
///
fn printCallback(context: void, string: []const u8) PrintError!void {
    try writeString(string);
}

///
/// Print a character without updating the cursor. For speed when printing a string as only need to
/// update the cursor once. This will also print the special characters: \n, \r, \t and \b
///
/// Arguments:
///     IN char: u8 - The character to print.
///
fn printLogo() void {
    const column_temp = column;
    const row_temp = row;

    column = 0;
    row = 0;

    writeString("                  _____    _        _    _   _______    ____  \n") catch unreachable;
    writeString("                 |  __ \\  | |      | |  | | |__   __|  / __ \\ \n") catch unreachable;
    writeString("                 | |__) | | |      | |  | |    | |    | |  | |\n") catch unreachable;
    writeString("                 |  ___/  | |      | |  | |    | |    | |  | |\n") catch unreachable;
    writeString("                 | |      | |____  | |__| |    | |    | |__| |\n") catch unreachable;
    writeString("                 |_|      |______|  \\____/     |_|     \\____/ \n") catch unreachable;

    column = column_temp;
    row = row_temp;
}

///
/// Print a formatted string to the terminal in the current colour. This used the standard zig
/// formatting.
///
/// Arguments:
///     IN format: []const u8 - The format string to print
///     IN args: ...          - The arguments to be used in the formatted string
///
pub fn print(comptime format: []const u8, args: ...) void {
    // Printing can't error because of the scrolling, if it does, we have a big problem
    fmt.format({}, PrintError, printCallback, format, args) catch unreachable;
}

///
/// Move up a page. This will copy the page above to the video buffer. Will keep trace of which
/// page is being displayed.
///
pub fn pageUp() void {
    if (page_index < TOTAL_NUM_PAGES - 1) {
        // Copy page to display
        page_index += 1;
        videoCopy(START_OF_DISPLAYABLE_REGION, pages[page_index][0..TOTAL_CHAR_ON_PAGE], TOTAL_CHAR_ON_PAGE) catch unreachable;
        displayPageNumber();
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
        videoCopy(START_OF_DISPLAYABLE_REGION, pages[page_index][0..TOTAL_CHAR_ON_PAGE], TOTAL_CHAR_ON_PAGE) catch unreachable;
        displayPageNumber();
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
    //row = ROW_MIN - 1 + vga.HEIGHT; // 42
    pagesMoveRowsUp(ROW_TOTAL) catch unreachable;

    // Clear the screen
    var i: u16 = START_OF_DISPLAYABLE_REGION;
    while (i < VIDEO_BUFFER_SIZE) : (i += 1) {
        video_buffer[i] = blank;
    }
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
///     new_colour: u8 - The new foreground and background colour of the screen.
///
pub fn setColour(new_colour: u8) void {
    colour = new_colour;
    blank = vga.entry(0, colour);
}

fn getVideoBufferAddress() usize {
    return @ptrToInt(&KERNEL_ADDR_OFFSET) + 0xB8000;
}

///
/// Initialise the tty. This will keep the bootloaders output and set the software cursor to where
/// the bootloader left it. Will copy the current screen to the pages, set the colour and blank
/// entry, print the logo and display the 0'th page.
///
pub fn init() void {
    log.logInfo("Init tty\n");
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
            row_offset = u16(ROW_MIN - (vga.HEIGHT - 1 - row));
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
        setVideoBuffer(blank, START_OF_DISPLAYABLE_REGION);
        row += @truncate(u8, row_offset + ROW_MIN);
    } else {
        // Clear the screen
        setVideoBuffer(blank, VIDEO_BUFFER_SIZE);
        // Set the row to below the logo
        row = ROW_MIN;
    }

    printLogo();
    displayPageNumber();
    updateCursor();
    log.logInfo("Done\n");
}

const test_colour: u8 = u8(vga.COLOUR_LIGHT_GREY) | u8(vga.COLOUR_BLACK) << 4;
var test_video_buffer = [_]u16{0} ** VIDEO_BUFFER_SIZE;

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

fn _setVideoBuffer() void {
    // Change to a stack location
    video_buffer = test_video_buffer[0..VIDEO_BUFFER_SIZE];

    expectEqual(@ptrToInt(video_buffer.ptr), @ptrToInt(&test_video_buffer[0]));

    colour = test_colour;
    blank = vga.mock_entry(0, test_colour);

    // Set pages to blank
    var i: u16 = 0;
    while (i < TOTAL_NUM_PAGES) : (i += 1) {
        var j: u16 = 0;
        while (j < TOTAL_CHAR_ON_PAGE) : (j += 1) {
            pages[i][j] = blank;
        }
    }
}

fn setVideoBufferBlankPages() void {
    _setVideoBuffer();
    for (video_buffer) |*b| {
        b.* = blank;
    }
}

fn setVideoBufferIncrementingBlankPages() void {
    _setVideoBuffer();
    var i: u16 = 0;
    while (i < VIDEO_BUFFER_SIZE) : (i += 1) {
        video_buffer[i] = i;
    }
}

fn setPagesIncrementing() void {
    var i: u16 = 0;
    while (i < TOTAL_NUM_PAGES) : (i += 1) {
        var j: u16 = 0;
        while (j < TOTAL_CHAR_ON_PAGE) : (j += 1) {
            pages[i][j] = i * TOTAL_CHAR_ON_PAGE + j;
        }
    }
}

fn defaultVariablesTesting(p_i: u8, r: u8, c: u8) void {
    expectEqual(test_colour, colour);
    expectEqual(u16(test_colour) << 8, blank);
    expectEqual(p_i, page_index);
    expectEqual(r, row);
    expectEqual(c, column);
}

fn incrementingPagesTesting() void {
    var i: u16 = 0;
    while (i < TOTAL_NUM_PAGES) : (i += 1) {
        var j: u16 = 0;
        while (j < TOTAL_CHAR_ON_PAGE) : (j += 1) {
            expectEqual(i * TOTAL_CHAR_ON_PAGE + j, pages[i][j]);
        }
    }
}

fn blankPagesTesting() void {
    var i: u16 = 0;
    while (i < TOTAL_NUM_PAGES) : (i += 1) {
        var j: u16 = 0;
        while (j < TOTAL_CHAR_ON_PAGE) : (j += 1) {
            expectEqual(blank, pages[i][j]);
        }
    }
}

fn incrementingVideoBufferTesting() void {
    var i: u16 = 0;
    while (i < VIDEO_BUFFER_SIZE) : (i += 1) {
        expectEqual(i, video_buffer[i]);
    }
}

fn defaultVideoBufferTesting() void {
    for (video_buffer) |b| {
        expectEqual(vga.mock_entry(0, test_colour), b);
    }
}

fn defaultAllTesting(p_i: u8, r: u8, c: u8) void {
    defaultVariablesTesting(p_i, r, c);
    blankPagesTesting();
    defaultVideoBufferTesting();
}

test "updateCursor" {
    // Set up
    setVideoBufferBlankPages();

    // Mocking out the vga.updateCursor call for updating the hardware cursor
    vga.initTest();
    defer vga.freeTest();

    vga.addTestParams("updateCursor", u16(0), u16(0));

    // Pre testing
    defaultAllTesting(0, 0, 0);

    // Call function
    updateCursor();

    // Post test
    defaultAllTesting(0, 0, 0);

    // Tear down
    resetGlobals();
}

test "getCursor zero" {
    // Set up
    setVideoBufferBlankPages();

    // Mocking out the vga.getCursor call for getting the hardware cursor
    vga.initTest();
    defer vga.freeTest();

    vga.addTestParams("getCursor", u16(0));

    // Pre testing
    defaultAllTesting(0, 0, 0);

    // Call function
    getCursor();

    // Post test
    defaultAllTesting(0, 0, 0);

    // Tear down
    resetGlobals();
}

test "getCursor EEF" {
    // Set up
    setVideoBufferBlankPages();

    // Mocking out the vga.getCursor call for getting the hardware cursor
    vga.initTest();
    defer vga.freeTest();

    vga.addTestParams("getCursor", u16(0x0EEF));

    // Pre testing
    defaultAllTesting(0, 0, 0);

    // Call function
    getCursor();

    // Post test
    defaultAllTesting(0, 47, 63);

    // Tear down
    resetGlobals();
}

test "displayPageNumber column and row is reset" {
    // Set up
    setVideoBufferBlankPages();
    column = 5;
    row = 6;

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("entry", vga.mock_entry);
    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    // Pre testing
    defaultAllTesting(0, 6, 5);

    // Call function
    displayPageNumber();

    // Post test
    defaultVariablesTesting(0, 6, 5);

    const text: [11]u8 = "Page 0 of 4";

    // Test both video and pages for page number 0
    for (video_buffer) |b, i| {
        if (i < START_OF_DISPLAYABLE_REGION - 11) {
            expectEqual(blank, b);
        } else if (i < START_OF_DISPLAYABLE_REGION) {
            expectEqual(vga.entry(text[i + 11 - START_OF_DISPLAYABLE_REGION], colour), b);
        } else {
            expectEqual(blank, b);
        }
    }

    // Tear down
    resetGlobals();
}

test "putEntryAt out of bounds" {
    // Set up
    setVideoBufferBlankPages();

    // Pre testing
    defaultAllTesting(0, 0, 0);

    // Call function
    expectError(PrintError.OutOfBounds, putEntryAt('A', 100, 100));

    // Post test
    defaultAllTesting(0, 0, 0);

    // Tear down
    resetGlobals();
}

test "putEntryAt not in displayable region" {
    // Set up
    setVideoBufferBlankPages();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("entry", vga.mock_entry);
    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    // Enable and update cursor is only called once, can can use the consume function call
    //vga.addConsumeFunction("enableCursor", vga.mock_enableCursor);

    // Pre testing
    defaultAllTesting(0, 0, 0);

    // Call function
    const x: u8 = 0;
    const y: u8 = 0;
    const char: u8 = 'A';
    putEntryAt(char, x, y) catch unreachable;

    // Post test
    defaultVariablesTesting(0, 0, 0);
    blankPagesTesting();

    for (video_buffer) |b, i| {
        if (i == y * vga.WIDTH + x) {
            expectEqual(vga.mock_entry(char, test_colour), b);
        } else {
            expectEqual(vga.mock_entry(0, test_colour), b);
        }
    }

    // Tear down
    resetGlobals();
}

test "putEntryAt in displayable region page_index is 0" {
    // Set up
    setVideoBufferBlankPages();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("entry", vga.mock_entry);
    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    // Pre testing
    defaultAllTesting(0, 0, 0);

    // Call function
    const x: u16 = 0;
    const y: u16 = ROW_MIN;
    const char: u8 = 'A';
    putEntryAt(char, x, y) catch unreachable;

    // Post test
    defaultVariablesTesting(0, 0, 0);
    for (pages) |page, i| {
        for (page) |c, j| {
            if ((i == page_index) and (j == (y * vga.WIDTH + x) - START_OF_DISPLAYABLE_REGION)) {
                expectEqual(vga.mock_entry(char, test_colour), c);
            } else {
                expectEqual(blank, c);
            }
        }
    }

    for (video_buffer) |b, i| {
        if (i == y * vga.WIDTH + x) {
            expectEqual(vga.mock_entry(char, test_colour), b);
        } else {
            expectEqual(vga.mock_entry(0, test_colour), b);
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

    vga.addRepeatFunction("entry", vga.mock_entry);
    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    // Enable and update cursor is only called once, can can use the consume function call
    vga.addConsumeFunction("enableCursor", vga.mock_enableCursor);

    setVideoBufferBlankPages();

    // Fill the 1'nd page (index 1) will all 1's
    const ones: u16 = vga.mock_entry('1', test_colour);
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
    defaultVariablesTesting(1, 0, 0);
    defaultVideoBufferTesting();

    for (pages) |page, i| {
        for (page) |char| {
            if (i == 0) {
                expectEqual(ones, char);
            } else {
                expectEqual(u16(0), char);
            }
        }
    }

    // Call function
    const x: u16 = 0;
    const y: u16 = ROW_MIN;
    const char: u8 = 'A';
    putEntryAt(char, x, y) catch unreachable;

    // Post test
    defaultVariablesTesting(0, 0, 0);

    const text: []const u8 = "Page 0 of 4";

    for (pages) |page, i| {
        for (page) |c, j| {
            if (i == 0 and j == 0) {
                expectEqual(vga.mock_entry(char, test_colour), c);
            } else if (i == 0) {
                expectEqual(ones, c);
            } else {
                expectEqual(u16(0), c);
            }
        }
    }

    // The top 7 rows won't be copied
    for (video_buffer) |b, i| {
        if (i < START_OF_DISPLAYABLE_REGION - 11) {
            expectEqual(blank, b);
        } else if (i < START_OF_DISPLAYABLE_REGION) {
            expectEqual(vga.mock_entry(text[i + 11 - START_OF_DISPLAYABLE_REGION], colour), b);
        } else if (i == y * vga.WIDTH + x) {
            expectEqual(vga.mock_entry(char, test_colour), b);
        } else {
            expectEqual(ones, b);
        }
    }

    // Tear down
    resetGlobals();
}

test "pagesMoveRowsUp out of bounds" {
    // Set up
    setVideoBufferBlankPages();
    setPagesIncrementing();

    // Pre testing
    defaultVariablesTesting(0, 0, 0);
    defaultVideoBufferTesting();
    incrementingPagesTesting();

    // Call function
    const rows_to_move: u16 = ROW_TOTAL + 1;
    expectError(PrintError.OutOfBounds, pagesMoveRowsUp(rows_to_move));

    // Post test
    defaultVariablesTesting(0, 0, 0);
    defaultVideoBufferTesting();
    incrementingPagesTesting();

    // Tear down
    resetGlobals();
}

test "pagesMoveRowsUp 0 rows" {
    // Set up
    setVideoBufferBlankPages();
    setPagesIncrementing();

    // Pre testing
    defaultVariablesTesting(0, 0, 0);
    defaultVideoBufferTesting();
    incrementingPagesTesting();

    // Call function
    const rows_to_move: u16 = 0;
    pagesMoveRowsUp(rows_to_move) catch unreachable;

    // Post test
    defaultVariablesTesting(0, 0, 0);
    defaultVideoBufferTesting();
    incrementingPagesTesting();

    // Tear down
    resetGlobals();
}

test "pagesMoveRowsUp 1 rows" {
    // Set up
    setVideoBufferBlankPages();
    setPagesIncrementing();

    // Pre testing
    defaultVariablesTesting(0, 0, 0);
    defaultVideoBufferTesting();
    incrementingPagesTesting();

    // Call function
    const rows_to_move: u16 = 1;
    pagesMoveRowsUp(rows_to_move) catch unreachable;

    // Post test
    defaultVariablesTesting(0, 0, 0);
    defaultVideoBufferTesting();

    var i: u16 = 0;
    const to_add: u16 = rows_to_move * vga.WIDTH;
    while (i < TOTAL_NUM_PAGES) : (i += 1) {
        var j: u16 = 0;
        while (j < TOTAL_CHAR_ON_PAGE) : (j += 1) {
            if (j >= TOTAL_CHAR_ON_PAGE - to_add) {
                if (i == 0) {
                    // The last rows will be blanks
                    expectEqual(blank, pages[i][j]);
                } else {
                    expectEqual((i - 1) * TOTAL_CHAR_ON_PAGE + (j + to_add - TOTAL_CHAR_ON_PAGE), pages[i][j]);
                }
            } else {
                // All rows moved up one, so add vga.WIDTH
                expectEqual(i * TOTAL_CHAR_ON_PAGE + j + to_add, pages[i][j]);
            }
        }
    }

    // Tear down
    resetGlobals();
}

test "pagesMoveRowsUp ROW_TOTAL - 1 rows" {
    // Set up
    setVideoBufferBlankPages();
    setPagesIncrementing();

    // Pre testing
    defaultVariablesTesting(0, 0, 0);
    defaultVideoBufferTesting();
    incrementingPagesTesting();

    // Call function
    const rows_to_move: u16 = ROW_TOTAL - 1;
    pagesMoveRowsUp(rows_to_move) catch unreachable;

    // Post test
    defaultVariablesTesting(0, 0, 0);
    defaultVideoBufferTesting();

    var i: u16 = 0;
    const to_add: u16 = rows_to_move * vga.WIDTH;
    while (i < TOTAL_NUM_PAGES) : (i += 1) {
        var j: u16 = 0;
        while (j < TOTAL_CHAR_ON_PAGE) : (j += 1) {
            if (j >= TOTAL_CHAR_ON_PAGE - to_add) {
                if (i == 0) {
                    // The last rows will be blanks
                    expectEqual(blank, pages[i][j]);
                } else {
                    expectEqual((i - 1) * TOTAL_CHAR_ON_PAGE + (j + to_add - TOTAL_CHAR_ON_PAGE), pages[i][j]);
                }
            } else {
                // All rows moved up one, so add vga.WIDTH
                expectEqual(i * TOTAL_CHAR_ON_PAGE + j + to_add, pages[i][j]);
            }
        }
    }

    // Tear down
    resetGlobals();
}

test "pagesMoveRowsUp ROW_TOTAL rows" {
    // Set up
    setVideoBufferBlankPages();
    setPagesIncrementing();

    // Pre testing
    defaultVariablesTesting(0, 0, 0);
    defaultVideoBufferTesting();
    incrementingPagesTesting();

    // Call function
    const rows_to_move: u16 = ROW_TOTAL;
    pagesMoveRowsUp(rows_to_move) catch unreachable;

    // Post test
    defaultVariablesTesting(0, 0, 0);
    defaultVideoBufferTesting();

    var i: u16 = 0;
    while (i < TOTAL_NUM_PAGES) : (i += 1) {
        var j: u16 = 0;
        while (j < TOTAL_CHAR_ON_PAGE) : (j += 1) {
            if (i == 0) {
                // The last rows will be blanks
                expectEqual(blank, pages[i][j]);
            } else {
                expectEqual((i - 1) * TOTAL_CHAR_ON_PAGE + j, pages[i][j]);
            }
        }
    }

    // Tear down
    resetGlobals();
}

test "scroll row is less then max height" {
    // Set up
    setVideoBufferBlankPages();
    setPagesIncrementing();

    // Pre testing
    defaultVariablesTesting(0, 0, 0);
    defaultVideoBufferTesting();
    incrementingPagesTesting();

    // Call function
    scroll();

    // Post test
    defaultVariablesTesting(0, 0, 0);
    defaultVideoBufferTesting();
    incrementingPagesTesting();

    // Tear down
    resetGlobals();
}

test "scroll row is equal to height" {
    // Set up
    setVideoBufferIncrementingBlankPages();
    setPagesIncrementing();

    const row_test: u16 = vga.HEIGHT;
    row = row_test;

    // Pre testing
    defaultVariablesTesting(0, row_test, 0);
    incrementingPagesTesting();
    incrementingVideoBufferTesting();

    // Call function
    // Rows move up one
    scroll();

    // Post test
    defaultVariablesTesting(0, vga.HEIGHT - 1, 0);

    var i: u16 = 0;
    const to_add: u16 = (row_test - vga.HEIGHT + 1) * vga.WIDTH;
    while (i < TOTAL_NUM_PAGES) : (i += 1) {
        var j: u16 = 0;
        while (j < TOTAL_CHAR_ON_PAGE) : (j += 1) {
            if (j >= TOTAL_CHAR_ON_PAGE - to_add) {
                if (i == 0) {
                    // The last rows will be blanks
                    expectEqual(blank, pages[i][j]);
                } else {
                    expectEqual((i - 1) * TOTAL_CHAR_ON_PAGE + (j + to_add - TOTAL_CHAR_ON_PAGE), pages[i][j]);
                }
            } else {
                // All rows moved up one, so add vga.WIDTH
                expectEqual(i * TOTAL_CHAR_ON_PAGE + j + to_add, pages[i][j]);
            }
        }
    }

    var k: u16 = 0;
    while (k < VIDEO_BUFFER_SIZE) : (k += 1) {
        if (k < START_OF_DISPLAYABLE_REGION) {
            expectEqual(k, video_buffer[k]);
        } else if (k >= VIDEO_BUFFER_SIZE - to_add) {
            expectEqual(blank, video_buffer[k]);
        } else {
            expectEqual(k + to_add, video_buffer[k]);
        }
    }

    // Tear down
    resetGlobals();
}

test "scroll row is more than height" {
    // Set up
    setVideoBufferIncrementingBlankPages();
    setPagesIncrementing();

    const row_test: u16 = vga.HEIGHT + 5;
    row = row_test;

    // Pre testing
    defaultVariablesTesting(0, row_test, 0);
    incrementingPagesTesting();
    incrementingVideoBufferTesting();

    // Call function
    // Rows move up 5
    scroll();

    // Post test
    defaultVariablesTesting(0, vga.HEIGHT - 1, 0);

    var i: u16 = 0;
    const to_add: u16 = (row_test - vga.HEIGHT + 1) * vga.WIDTH;
    while (i < TOTAL_NUM_PAGES) : (i += 1) {
        var j: u16 = 0;
        while (j < TOTAL_CHAR_ON_PAGE) : (j += 1) {
            if (j >= TOTAL_CHAR_ON_PAGE - to_add) {
                if (i == 0) {
                    // The last rows will be blanks
                    expectEqual(blank, pages[i][j]);
                } else {
                    expectEqual((i - 1) * TOTAL_CHAR_ON_PAGE + (j + to_add - TOTAL_CHAR_ON_PAGE), pages[i][j]);
                }
            } else {
                // All rows moved up one, so add vga.WIDTH
                expectEqual(i * TOTAL_CHAR_ON_PAGE + j + to_add, pages[i][j]);
            }
        }
    }

    var k: u16 = 0;
    while (k < VIDEO_BUFFER_SIZE) : (k += 1) {
        if (k < START_OF_DISPLAYABLE_REGION) {
            expectEqual(k, video_buffer[k]);
        } else if (k >= VIDEO_BUFFER_SIZE - to_add) {
            expectEqual(blank, video_buffer[k]);
        } else {
            expectEqual(k + to_add, video_buffer[k]);
        }
    }

    // Tear down
    resetGlobals();
}

test "putChar new line within screen" {
    // Set up
    setVideoBufferBlankPages();

    // Pre testing
    column = 5;
    row = 5;
    defaultAllTesting(0, 5, 5);

    // Call function
    putChar('\n') catch unreachable;

    // Post test
    defaultAllTesting(0, 6, 0);

    // Tear down
    resetGlobals();
}

test "putChar new line outside screen" {
    // Set up
    setVideoBufferBlankPages();

    // Pre testing
    column = 5;
    row = vga.HEIGHT - 1;
    defaultAllTesting(0, vga.HEIGHT - 1, 5);

    // Call function
    putChar('\n') catch unreachable;

    // Post test
    defaultAllTesting(0, vga.HEIGHT - 1, 0);

    // Tear down
    resetGlobals();
}

test "putChar tab within line" {
    // Set up
    setVideoBufferBlankPages();

    // Pre testing
    column = 5;
    row = 6;
    defaultAllTesting(0, 6, 5);

    // Call function
    putChar('\t') catch unreachable;

    // Post test
    defaultAllTesting(0, 6, 9);

    // Tear down
    resetGlobals();
}

test "putChar tab end of line" {
    // Set up
    setVideoBufferBlankPages();

    // Pre testing
    column = vga.WIDTH - 1;
    row = 6;
    defaultAllTesting(0, 6, vga.WIDTH - 1);

    // Call function
    putChar('\t') catch unreachable;

    // Post test
    defaultAllTesting(0, 7, 3);

    // Tear down
    resetGlobals();
}

test "putChar tab end of screen" {
    // Set up
    setVideoBufferBlankPages();

    // Pre testing
    column = vga.WIDTH - 1;
    row = vga.HEIGHT - 1;
    defaultAllTesting(0, vga.HEIGHT - 1, vga.WIDTH - 1);

    // Call function
    putChar('\t') catch unreachable;

    // Post test
    defaultAllTesting(0, vga.HEIGHT - 1, 3);

    // Tear down
    resetGlobals();
}

test "putChar line feed" {
    // Set up
    setVideoBufferBlankPages();

    // Pre testing
    column = vga.WIDTH - 1;
    row = vga.HEIGHT - 1;
    defaultAllTesting(0, vga.HEIGHT - 1, vga.WIDTH - 1);

    // Call function
    putChar('\r') catch unreachable;

    // Post test
    defaultAllTesting(0, vga.HEIGHT - 1, 0);

    // Tear down
    resetGlobals();
}

test "putChar back char top left of screen" {
    // Set up
    setVideoBufferBlankPages();

    // Pre testing
    defaultAllTesting(0, 0, 0);

    // Call function
    putChar('\x08') catch unreachable;

    // Post test
    defaultAllTesting(0, 0, 0);

    // Tear down
    resetGlobals();
}

test "putChar back char top row" {
    // Set up
    setVideoBufferBlankPages();

    // Pre testing
    column = 8;
    defaultAllTesting(0, 0, 8);

    // Call function
    putChar('\x08') catch unreachable;

    // Post test
    defaultAllTesting(0, 0, 7);

    // Tear down
    resetGlobals();
}

test "putChar back char beginning of row" {
    // Set up
    setVideoBufferBlankPages();

    // Pre testing
    row = 1;
    defaultAllTesting(0, 1, 0);

    // Call function
    putChar('\x08') catch unreachable;

    // Post test
    defaultAllTesting(0, 0, vga.WIDTH - 1);

    // Tear down
    resetGlobals();
}

test "putChar any char in row" {
    // Set up
    setVideoBufferBlankPages();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("entry", vga.mock_entry);

    // Pre testing
    defaultAllTesting(0, 0, 0);

    // Call function
    putChar('A') catch unreachable;

    // Post test
    defaultVariablesTesting(0, 0, 1);
    blankPagesTesting();

    var k: u16 = 0;
    while (k < VIDEO_BUFFER_SIZE) : (k += 1) {
        if (k == 0) {
            expectEqual(vga.mock_entry('A', colour), video_buffer[k]);
        } else {
            expectEqual(blank, video_buffer[k]);
        }
    }

    // Tear down
    resetGlobals();
}

test "putChar any char end of row" {
    // Set up
    setVideoBufferBlankPages();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("entry", vga.mock_entry);

    // Pre testing
    column = vga.WIDTH - 1;
    defaultAllTesting(0, 0, vga.WIDTH - 1);

    // Call function
    putChar('A') catch unreachable;

    // Post test
    defaultVariablesTesting(0, 1, 0);
    blankPagesTesting();

    var k: u16 = 0;
    while (k < VIDEO_BUFFER_SIZE) : (k += 1) {
        if (k == vga.WIDTH - 1) {
            expectEqual(vga.entry('A', colour), video_buffer[k]);
        } else {
            expectEqual(blank, video_buffer[k]);
        }
    }

    // Tear down
    resetGlobals();
}

test "putChar any char end of screen" {
    // Set up
    setVideoBufferBlankPages();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("entry", vga.mock_entry);

    // Pre testing
    row = vga.HEIGHT - 1;
    column = vga.WIDTH - 1;
    defaultAllTesting(0, vga.HEIGHT - 1, vga.WIDTH - 1);

    // Call function
    putChar('A') catch unreachable;

    // Post test
    defaultVariablesTesting(0, vga.HEIGHT - 1, 0);
    for (pages) |page, i| {
        for (page) |c, j| {
            if ((i == 0) and (j == TOTAL_CHAR_ON_PAGE - vga.WIDTH - 1)) {
                expectEqual(vga.entry('A', colour), c);
            } else {
                expectEqual(blank, c);
            }
        }
    }

    var k: u16 = 0;
    while (k < VIDEO_BUFFER_SIZE) : (k += 1) {
        if (k == VIDEO_BUFFER_SIZE - vga.WIDTH - 1) {
            expectEqual(vga.entry('A', colour), video_buffer[k]);
        } else {
            expectEqual(blank, video_buffer[k]);
        }
    }

    // Tear down
    resetGlobals();
}

test "printLogo all" {
    // Set up
    setVideoBufferBlankPages();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("entry", vga.mock_entry);
    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    // Pre testing
    column = 0;
    row = ROW_MIN;

    defaultAllTesting(0, ROW_MIN, 0);

    // Call function
    printLogo();

    // Post test
    defaultVariablesTesting(0, ROW_MIN, 0);
    blankPagesTesting();

    var k: u16 = 0;
    while (k < VIDEO_BUFFER_SIZE) : (k += 1) {
        if (k < START_OF_DISPLAYABLE_REGION) {
            // This is where the logo will be, but is a complex string so no testing
            // Just take my word it works :P
        } else {
            expectEqual(blank, video_buffer[k]);
        }
    }

    // Tear down
    resetGlobals();
}

test "pageUp top page" {
    // Set up
    setVideoBufferBlankPages();
    setPagesIncrementing();

    // Pre testing
    page_index = TOTAL_NUM_PAGES - 1;

    defaultVariablesTesting(TOTAL_NUM_PAGES - 1, 0, 0);
    incrementingPagesTesting();
    defaultVideoBufferTesting();

    // Call function
    pageUp();

    // Post test
    defaultVariablesTesting(TOTAL_NUM_PAGES - 1, 0, 0);
    incrementingPagesTesting();
    defaultVideoBufferTesting();

    // Tear down
    resetGlobals();
}

test "pageUp bottom page" {
    // Set up
    setVideoBufferBlankPages();
    setPagesIncrementing();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("entry", vga.mock_entry);
    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    vga.addConsumeFunction("disableCursor", vga.mock_disableCursor);

    // Pre testing
    defaultVariablesTesting(0, 0, 0);
    incrementingPagesTesting();
    defaultVideoBufferTesting();

    // Call function
    pageUp();

    // Post test
    defaultVariablesTesting(1, 0, 0);
    incrementingPagesTesting();

    const text: []const u8 = "Page 1 of 4";

    for (video_buffer) |b, i| {
        // Ignore the ROW_MIN row as this is where the page number is printed and is already
        // tested, page number is printed 11 from the end
        if (i < START_OF_DISPLAYABLE_REGION - 11) {
            expectEqual(blank, b);
        } else if (i < START_OF_DISPLAYABLE_REGION) {
            expectEqual(vga.mock_entry(text[i + 11 - START_OF_DISPLAYABLE_REGION], colour), b);
        } else {
            expectEqual(i - START_OF_DISPLAYABLE_REGION + TOTAL_CHAR_ON_PAGE, b);
        }
    }

    // Tear down
    resetGlobals();
}

test "pageDown bottom page" {
    // Set up
    setVideoBufferBlankPages();
    setPagesIncrementing();

    // Pre testing
    defaultVariablesTesting(0, 0, 0);
    incrementingPagesTesting();
    defaultVideoBufferTesting();

    // Call function
    pageDown();

    // Post test
    defaultVariablesTesting(0, 0, 0);
    incrementingPagesTesting();
    defaultVideoBufferTesting();

    // Tear down
    resetGlobals();
}

test "pageDown top page" {
    // Set up
    setVideoBufferBlankPages();
    setPagesIncrementing();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("entry", vga.mock_entry);
    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    vga.addConsumeFunction("disableCursor", vga.mock_disableCursor);

    // Pre testing
    page_index = TOTAL_NUM_PAGES - 1;

    defaultVariablesTesting(TOTAL_NUM_PAGES - 1, 0, 0);
    incrementingPagesTesting();
    defaultVideoBufferTesting();

    // Call function
    pageDown();

    // Post test
    defaultVariablesTesting(TOTAL_NUM_PAGES - 2, 0, 0);
    incrementingPagesTesting();

    const text: []const u8 = "Page 3 of 4";

    for (video_buffer) |b, i| {
        // Ignore the ROW_MIN row as this is where the page number is printed and is already
        // tested, page number is printed 11 from the end
        if (i < START_OF_DISPLAYABLE_REGION - 11) {
            expectEqual(blank, b);
        } else if (i < START_OF_DISPLAYABLE_REGION) {
            expectEqual(vga.mock_entry(text[i + 11 - START_OF_DISPLAYABLE_REGION], colour), b);
        } else {
            expectEqual((i - START_OF_DISPLAYABLE_REGION) + (TOTAL_CHAR_ON_PAGE * page_index), b);
        }
    }

    // Tear down
    resetGlobals();
}

test "clearScreen all" {
    // Set up
    setVideoBufferIncrementingBlankPages();
    setPagesIncrementing();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    // Pre testing
    defaultVariablesTesting(0, 0, 0);
    incrementingVideoBufferTesting();
    incrementingPagesTesting();

    // Call function
    clearScreen();

    // Post test
    defaultVariablesTesting(0, ROW_MIN, 0);
    var k: u16 = 0;
    while (k < VIDEO_BUFFER_SIZE) : (k += 1) {
        if (k < START_OF_DISPLAYABLE_REGION) {
            expectEqual(k, video_buffer[k]);
        } else {
            expectEqual(blank, video_buffer[k]);
        }
    }

    var i: u16 = 0;
    while (i < TOTAL_NUM_PAGES) : (i += 1) {
        var j: u16 = 0;
        while (j < TOTAL_CHAR_ON_PAGE) : (j += 1) {
            if (i == 0) {
                // The last rows will be blanks
                expectEqual(blank, pages[i][j]);
            } else {
                expectEqual((i - 1) * TOTAL_CHAR_ON_PAGE + j, pages[i][j]);
            }
        }
    }

    // Tear down
    resetGlobals();
}

test "moveCursorLeft top left of screen" {
    // Set up
    setVideoBufferBlankPages();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    // Pre testing
    defaultAllTesting(0, 0, 0);

    // Call function
    moveCursorLeft();

    // Post test
    defaultAllTesting(0, 0, 0);

    // Tear down
    resetGlobals();
}

test "moveCursorLeft top screen" {
    // Set up
    setVideoBufferBlankPages();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    // Pre testing
    column = 5;
    defaultAllTesting(0, 0, 5);

    // Call function
    moveCursorLeft();

    // Post test
    defaultAllTesting(0, 0, 4);

    // Tear down
    resetGlobals();
}

test "moveCursorLeft start of row" {
    // Set up
    setVideoBufferBlankPages();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    // Pre testing
    row = 5;
    defaultAllTesting(0, 5, 0);

    // Call function
    moveCursorLeft();

    // Post test
    defaultAllTesting(0, 4, vga.WIDTH - 1);

    // Tear down
    resetGlobals();
}

test "moveCursorRight bottom right of screen" {
    // Set up
    setVideoBufferBlankPages();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    // Pre testing
    row = vga.HEIGHT - 1;
    column = vga.WIDTH - 1;
    defaultAllTesting(0, vga.HEIGHT - 1, vga.WIDTH - 1);

    // Call function
    moveCursorRight();

    // Post test
    defaultAllTesting(0, vga.HEIGHT - 1, vga.WIDTH - 1);

    // Tear down
    resetGlobals();
}

test "moveCursorRight top screen" {
    // Set up
    setVideoBufferBlankPages();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    // Pre testing
    column = 5;
    defaultAllTesting(0, 0, 5);

    // Call function
    moveCursorRight();

    // Post test
    defaultAllTesting(0, 0, 6);

    // Tear down
    resetGlobals();
}

test "moveCursorRight end of row" {
    // Set up
    setVideoBufferBlankPages();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    // Pre testing
    row = 5;
    column = vga.WIDTH - 1;
    defaultAllTesting(0, 5, vga.WIDTH - 1);

    // Call function
    moveCursorRight();

    // Post test
    defaultAllTesting(0, 6, 0);

    // Tear down
    resetGlobals();
}

test "setColour all" {
    // Set up
    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addConsumeFunction("entry", vga.mock_entry);

    // Pre testing

    // Call function
    const new_colour: u8 = vga.mock_entryColour(vga.COLOUR_WHITE, vga.COLOUR_WHITE);
    setColour(new_colour);

    // Post test
    expectEqual(new_colour, colour);
    expectEqual(vga.mock_entry(0, new_colour), blank);

    // Tear down
    resetGlobals();
}

test "writeString all" {
    // Set up
    setVideoBufferBlankPages();

    // Mocking out the vga calls
    vga.initTest();
    defer vga.freeTest();

    vga.addRepeatFunction("entry", vga.mock_entry);

    vga.addConsumeFunction("updateCursor", vga.mock_updateCursor);

    // Pre testing
    row = ROW_MIN;
    defaultAllTesting(0, ROW_MIN, 0);

    // Call function
    writeString("ABC") catch unreachable;

    // Post test
    defaultVariablesTesting(0, ROW_MIN, 3);
    for (pages) |page, i| {
        for (page) |c, j| {
            if ((i == 0) and (j == 0)) {
                expectEqual(vga.mock_entry('A', colour), c);
            } else if ((i == 0) and (j == 1)) {
                expectEqual(vga.mock_entry('B', colour), c);
            } else if ((i == 0) and (j == 2)) {
                expectEqual(vga.mock_entry('C', colour), c);
            } else {
                expectEqual(blank, c);
            }
        }
    }

    var k: u16 = 0;
    while (k < VIDEO_BUFFER_SIZE) : (k += 1) {
        if (k == START_OF_DISPLAYABLE_REGION) {
            expectEqual(vga.mock_entry('A', colour), video_buffer[k]);
        } else if (k == START_OF_DISPLAYABLE_REGION + 1) {
            expectEqual(vga.mock_entry('B', colour), video_buffer[k]);
        } else if (k == START_OF_DISPLAYABLE_REGION + 2) {
            expectEqual(vga.mock_entry('C', colour), video_buffer[k]);
        } else {
            expectEqual(blank, video_buffer[k]);
        }
    }

    // Tear down
    resetGlobals();
}

test "init 0,0" {
    // Set up
    setVideoBufferBlankPages();

    // Mocking out the vga.updateCursor call for updating the hardware cursor
    vga.initTest();
    defer vga.freeTest();

    vga.addTestParams("getCursor", u16(0));

    vga.addRepeatFunction("entryColour", vga.mock_entryColour);
    vga.addRepeatFunction("entry", vga.mock_entry);
    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    vga.addConsumeFunction("enableCursor", vga.mock_enableCursor);

    // Pre testing
    defaultAllTesting(0, 0, 0);

    // Call function
    init();

    // Post test
    defaultVariablesTesting(0, ROW_MIN, 0);
    blankPagesTesting();

    var k: u16 = 0;
    while (k < VIDEO_BUFFER_SIZE) : (k += 1) {
        if (k < START_OF_DISPLAYABLE_REGION) {
            // This is where the logo will be, but is a complex string so no testing
            // Just take my word it works :P
        } else {
            expectEqual(blank, video_buffer[k]);
        }
    }

    // Tear down
    resetGlobals();
}

test "init not 0,0" {
    // Set up
    setVideoBufferBlankPages();

    // Mocking out the vga.updateCursor call for updating the hardware cursor
    vga.initTest();
    defer vga.freeTest();

    vga.addTestParams("getCursor", vga.WIDTH);

    vga.addRepeatFunction("entryColour", vga.mock_entryColour);
    vga.addRepeatFunction("entry", vga.mock_entry);
    vga.addRepeatFunction("updateCursor", vga.mock_updateCursor);

    vga.addConsumeFunction("enableCursor", vga.mock_enableCursor);

    // Pre testing
    defaultAllTesting(0, 0, 0);

    // Call function
    init();

    // Post test
    defaultVariablesTesting(0, ROW_MIN + 1, 0);
    blankPagesTesting();

    var k: u16 = 0;
    while (k < VIDEO_BUFFER_SIZE) : (k += 1) {
        if (k < START_OF_DISPLAYABLE_REGION) {
            // This is where the logo will be, but is a complex string so no testing
            // Just take my word it works :P
        } else {
            expectEqual(blank, video_buffer[k]);
        }
    }

    // Tear down
    resetGlobals();
}

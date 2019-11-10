const std = @import("std");
const StringHashMap = std.StringHashMap;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const GlobalAllocator = std.debug.global_allocator;
const TailQueue = std.TailQueue;
const warn = std.debug.warn;
const gdt = @import("gdt_mock.zig");
const idt = @import("idt_mock.zig");

///
/// The enumeration of types that the mocking framework supports. These include basic types like u8
/// and function types like fn () void
///
const DataElementType = enum {
    BOOL,
    U4,
    U8,
    U16,
    U32,
    PTR_CONST_GdtPtr,
    PTR_CONST_IdtPtr,
    ERROR_IDTERROR_VOID,
    EFN_OVOID,
    NFN_OVOID,
    FN_OVOID,
    FN_OUSIZE,
    FN_OU16,
    FN_IU8_OBOOL,
    FN_IU8_OVOID,
    FN_IU16_OVOID,
    FN_IU16_OU8,
    FN_IU4_IU4_OU8,
    FN_IU8_IU8_OU16,
    FN_IU16_IU8_OVOID,
    FN_IU16_IU16_OVOID,
    FN_IU8_IEFNOVOID_OERRORIDTERRORVOID,
    FN_IU8_INFNOVOID_OERRORIDTERRORVOID,
    FN_IPTRCONSTGDTPTR_OVOID,
    FN_IPTRCONSTIDTPTR_OVOID,
};

///
/// A tagged union of all the data elements that the mocking framework can work with. This can be
/// expanded to add new types. This is needed as need a list of data that all have different types,
/// so this wraps the data into a union, (which is of one type) so can have a list of them.
///
const DataElement = union(DataElementType) {
    BOOL: bool,
    U4: u4,
    U8: u8,
    U16: u16,
    U32: u32,
    PTR_CONST_GdtPtr: *const gdt.GdtPtr,
    PTR_CONST_IdtPtr: *const idt.IdtPtr,
    ERROR_IDTERROR_VOID: idt.IdtError!void,
    EFN_OVOID: extern fn () void,
    NFN_OVOID: nakedcc fn () void,
    FN_OVOID: fn () void,
    FN_OUSIZE: fn () usize,
    FN_OU16: fn () u16,
    FN_IU8_OBOOL: fn (u8) bool,
    FN_IU8_OVOID: fn (u8) void,
    FN_IU16_OVOID: fn (u16) void,
    FN_IU16_OU8: fn (u16) u8,
    FN_IU4_IU4_OU8: fn (u4, u4) u8,
    FN_IU8_IU8_OU16: fn (u8, u8) u16,
    FN_IU16_IU8_OVOID: fn (u16, u8) void,
    FN_IU16_IU16_OVOID: fn (u16, u16) void,
    FN_IU8_IEFNOVOID_OERRORIDTERRORVOID: fn (u8, extern fn () void) idt.IdtError!void,
    FN_IU8_INFNOVOID_OERRORIDTERRORVOID: fn (u8, nakedcc fn () void) idt.IdtError!void,
    FN_IPTRCONSTGDTPTR_OVOID: fn (*const gdt.GdtPtr) void,
    FN_IPTRCONSTIDTPTR_OVOID: fn (*const idt.IdtPtr) void,
};

///
/// The type of actions that the mocking framework can perform.
///
const ActionType = enum {
    /// This will test the parameters passed to a function. It will test the correct types and
    /// value of each parameter. This is also used to return a specific value from a function so
    /// can test for returns from a function.
    TestValue,

    /// This action is to replace a function call to be mocked with another function the user
    /// chooses to be replaced. This will consume the function call. This will allow the user to
    /// check that the function is called once or multiple times by added a function to be mocked
    /// multiple times. This also allows the ability for a function to be mocked by different
    /// functions each time it is called.
    ConsumeFunctionCall,

    /// This is similar to the ConsumeFunctionCall action, but will call the mocked function
    /// repeatedly until the mocking is done.
    RepeatFunctionCall,

    // Other actions that could be used

    // This will check that a function isn't called.
    //NoFunctionCall

    // This is a generalisation of ConsumeFunctionCall and RepeatFunctionCall but can specify how
    // many times a function can be called.
    //FunctionCallN
};

///
/// This is a pair of action and data to be actioned on.
///
const Action = struct {
    action: ActionType,
    data: DataElement,
};

///
/// The type for a queue of actions using std.TailQueue.
///
const ActionList = TailQueue(Action);

///
/// The type for linking the function name to be mocked and the action list to be acted on.
///
const NamedActionMap = StringHashMap(ActionList);

///
/// The mocking framework.
///
/// Return: type
///     This returns a struct for adding and acting on mocked functions.
///
fn Mock() type {
    return struct {
        const Self = @This();

        /// The map of function name and action list.
        named_actions: NamedActionMap,

        ///
        /// Create a DataElement from data. This wraps data into a union. This allows the ability
        /// to have a list of different types.
        ///
        /// Arguments:
        ///     IN arg: var - The data, this can be a function or basic type value.
        ///
        /// Return: DataElement
        ///     A DataElement with the data wrapped.
        ///
        fn createDataElement(arg: var) DataElement {
            return switch (@typeOf(arg)) {
                bool => DataElement{ .BOOL = arg },
                u4 => DataElement{ .U4 = arg },
                u8 => DataElement{ .U8 = arg },
                u16 => DataElement{ .U16 = arg },
                u32 => DataElement{ .U32 = arg },
                *const gdt.GdtPtr => DataElement{ .PTR_CONST_GdtPtr = arg },
                *const idt.IdtPtr => DataElement{ .PTR_CONST_IdtPtr = arg },
                idt.IdtError!void => DataElement{ .ERROR_IDTERROR_VOID = arg },
                extern fn () void => DataElement{ .EFN_OVOID = arg },
                nakedcc fn () void => DataElement{ .NFN_OVOID = arg },
                fn () void => DataElement{ .FN_OVOID = arg },
                fn () usize => DataElement{ .FN_OUSIZE = arg },
                fn () u16 => DataElement{ .FN_OU16 = arg },
                fn (u8) bool => DataElement{ .FN_IU8_OBOOL = arg },
                fn (u8) void => DataElement{ .FN_IU8_OVOID = arg },
                fn (u16) void => DataElement{ .FN_IU16_OVOID = arg },
                fn (u16) u8 => DataElement{ .FN_IU16_OU8 = arg },
                fn (u4, u4) u8 => DataElement{ .FN_IU4_IU4_OU8 = arg },
                fn (u8, u8) u16 => DataElement{ .FN_IU8_IU8_OU16 = arg },
                fn (u16, u8) void => DataElement{ .FN_IU16_IU8_OVOID = arg },
                fn (u16, u16) void => DataElement{ .FN_IU16_IU16_OVOID = arg },
                fn (*const gdt.GdtPtr) void => DataElement{ .FN_IPTRCONSTGDTPTR_OVOID = arg },
                fn (*const idt.IdtPtr) void => DataElement{ .FN_IPTRCONSTIDTPTR_OVOID = arg },
                fn (u8, extern fn () void) idt.IdtError!void => DataElement{ .FN_IU8_IEFNOVOID_OERRORIDTERRORVOID = arg },
                fn (u8, nakedcc fn () void) idt.IdtError!void => DataElement{ .FN_IU8_INFNOVOID_OERRORIDTERRORVOID = arg },
                else => @compileError("Type not supported: " ++ @typeName(@typeOf(arg))),
            };
        }

        ///
        /// Get the enum that represents the type given.
        ///
        /// Arguments:
        ///     IN T: type - A type.
        ///
        /// Return: DataElementType
        ///     The DataElementType that represents the type given.
        ///
        fn getDataElementType(comptime T: type) DataElementType {
            return switch (T) {
                bool => DataElementType.BOOL,
                u4 => DataElementType.U4,
                u8 => DataElementType.U8,
                u16 => DataElementType.U16,
                u32 => DataElementType.U32,
                *const gdt.GdtPtr => DataElement.PTR_CONST_GdtPtr,
                *const idt.IdtPtr => DataElement.PTR_CONST_IdtPtr,
                idt.IdtError!void => DataElement.ERROR_IDTERROR_VOID,
                extern fn () void => DataElementType.EFN_OVOID,
                nakedcc fn () void => DataElementType.NFN_OVOID,
                fn () void => DataElementType.FN_OVOID,
                fn () u16 => DataElementType.FN_OU16,
                fn (u8) bool => DataElementType.FN_IU8_OBOOL,
                fn (u8) void => DataElementType.FN_IU8_OVOID,
                fn (u16) void => DataElementType.FN_IU16_OVOID,
                fn (u16) u8 => DataElementType.FN_IU16_OU8,
                fn (u4, u4) u8 => DataElementType.FN_IU4_IU4_OU8,
                fn (u8, u8) u16 => DataElementType.FN_IU8_IU8_OU16,
                fn (u16, u8) void => DataElementType.FN_IU16_IU8_OVOID,
                fn (u16, u16) void => DataElementType.FN_IU16_IU16_OVOID,
                fn (*const gdt.GdtPtr) void => DataElementType.FN_IPTRCONSTGDTPTR_OVOID,
                fn (*const idt.IdtPtr) void => DataElementType.FN_IPTRCONSTIDTPTR_OVOID,
                fn (u8, extern fn () void) idt.IdtError!void => DataElementType.FN_IU8_IEFNOVOID_OERRORIDTERRORVOID,
                fn (u8, nakedcc fn () void) idt.IdtError!void => DataElementType.FN_IU8_INFNOVOID_OERRORIDTERRORVOID,
                else => @compileError("Type not supported: " ++ @typeName(T)),
            };
        }

        ///
        /// Get the data out of the tagged union
        ///
        /// Arguments:
        ///     IN T: type              - The type of the data to extract. Used to switch on the
        ///                               tagged union.
        ///     IN element: DataElement - The data element to unwrap the data from.
        ///
        /// Return: T
        ///     The data of type T from the DataElement.
        ///
        fn getDataValue(comptime T: type, element: DataElement) T {
            return switch (T) {
                bool => element.BOOL,
                u4 => element.U4,
                u8 => element.U8,
                u16 => element.U16,
                u32 => element.U32,
                *const gdt.GdtPtr => element.PTR_CONST_GdtPtr,
                *const idt.IdtPtr => element.PTR_CONST_IdtPtr,
                idt.IdtError!void => element.ERROR_IDTERROR_VOID,
                extern fn () void => element.EFN_OVOID,
                nakedcc fn () void => element.NFN_OVOID,
                fn () void => element.FN_OVOID,
                fn () u16 => element.FN_OU16,
                fn (u8) bool => element.FN_IU8_OBOOL,
                fn (u8) void => element.FN_IU8_OVOID,
                fn (u16) void => element.FN_IU16_OVOID,
                fn (u16) u8 => element.FN_IU16_OU8,
                fn (u4, u4) u8 => element.FN_IU4_IU4_OU8,
                fn (u8, u8) u16 => element.FN_IU8_IU8_OU16,
                fn (u16, u8) void => element.FN_IU16_IU8_OVOID,
                fn (u16, u16) void => element.FN_IU16_IU16_OVOID,
                fn (*const gdt.GdtPtr) void => element.FN_IPTRCONSTGDTPTR_OVOID,
                fn (*const idt.IdtPtr) void => element.FN_IPTRCONSTIDTPTR_OVOID,
                fn (u8, extern fn () void) idt.IdtError!void => element.FN_IU8_IEFNOVOID_OERRORIDTERRORVOID,
                fn (u8, nakedcc fn () void) idt.IdtError!void => element.FN_IU8_INFNOVOID_OERRORIDTERRORVOID,
                else => @compileError("Type not supported: " ++ @typeName(T)),
            };
        }

        ///
        /// Create a function type from a return type and its arguments. Waiting for
        /// https://github.com/ziglang/zig/issues/313. TODO: Tidy mocking framework #69
        ///
        /// Arguments:
        ///     IN RetType: type   - The return type of the function.
        ///     IN params: arglist - The argument list for the function.
        ///
        /// Return: type
        ///     A function type that represents the return type and its arguments.
        ///
        fn getFunctionType(comptime RetType: type, params: ...) type {
            return switch (params.len) {
                0 => fn () RetType,
                1 => fn (@typeOf(params[0])) RetType,
                2 => fn (@typeOf(params[0]), @typeOf(params[1])) RetType,
                else => @compileError("Couldn't generate function type for " ++ params.len ++ "parameters\n"),
            };
        }

        ///
        /// This tests a value passed to a function.
        ///
        /// Arguments:
        ///     IN ExpectedType: type           - The expected type of the value to be tested.
        ///     IN expected_value: ExpectedType - The expected value to be tested. This is what was
        ///                                       passed to the functions.
        ///     IN elem: DataElement            - The wrapped data element to test against the
        ///                                       expected value.
        ///
        fn expectTest(comptime ExpectedType: type, expected_value: ExpectedType, elem: DataElement) void {
            if (ExpectedType == void) {
                // Can't test void as it has no value
                std.debug.panic("Can not test a value for void\n");
            }

            // Test that the types match
            const expect_type = comptime getDataElementType(ExpectedType);
            expectEqual(expect_type, @as(DataElementType, elem));

            // Types match, so can use the expected type to get the actual data
            const actual_value = getDataValue(ExpectedType, elem);

            // Test the values
            expectEqual(expected_value, actual_value);
        }

        ///
        /// This returns a value from the wrapped data element. This will be a test value to be
        /// returned by a mocked function.
        ///
        /// Arguments:
        ///     IN fun_name: []const u8         - The function name to be used to tell the user if
        ///                                       there is no return value set up.
        ///     IN/OUT action_list: *ActionList - The action list to extract the return value from.
        ///     IN DataType: type               - The type of the return value.
        ///
        fn expectGetValue(comptime fun_name: []const u8, action_list: *ActionList, comptime DataType: type) DataType {
            if (DataType == void) {
                return;
            }

            if (action_list.*.popFirst()) |action_node| {
                const action = action_node.data;
                const expect_type = getDataElementType(DataType);

                const ret = getDataValue(DataType, action.data);

                expectEqual(@as(DataElementType, action.data), expect_type);

                // Free the node
                action_list.*.destroyNode(action_node, GlobalAllocator);

                return ret;
            } else {
                std.debug.panic("No more test values for the return of function: " ++ fun_name ++ "\n");
            }
        }

        ///
        /// This adds a action to the action list with ActionType provided. It will create a new
        /// mapping if one doesn't exist for a function name.
        ///
        /// Arguments:
        ///     IN/OUT self: *Self         - Self. This is the mocking object to be modified to add
        ///                                  the test data.
        ///     IN fun_name: []const u8    - The function name to add the test parameters to.
        ///     IN data: var               - The data to add.
        ///     IN action_type: ActionType - The action type to add.
        ///
        pub fn addAction(self: *Self, comptime fun_name: []const u8, data: var, action_type: ActionType) void {
            // Add a new mapping if one doesn't exist.
            if (!self.named_actions.contains(fun_name)) {
                expect(self.named_actions.put(fun_name, TailQueue(Action).init()) catch unreachable == null);
            }

            // Get the function mapping to add the parameter to.
            if (self.named_actions.get(fun_name)) |actions_kv| {
                var action_list = actions_kv.value;
                const action = Action{
                    .action = action_type,
                    .data = createDataElement(data),
                };
                var a = action_list.createNode(action, GlobalAllocator) catch unreachable;
                action_list.append(a);
                // Need to re-assign the value as it isn't updated when we just append
                actions_kv.value = action_list;
            } else {
                // Shouldn't get here as we would have just added a new mapping
                // But just in case ;)
                std.debug.panic("No function name: " ++ fun_name ++ "\n");
            }
        }

        ///
        /// Perform an action on a function. This can be one of ActionType.
        ///
        /// Arguments:
        ///     IN/OUT self: *Self      - Self. This is the mocking object to be modified to
        ///                               perform a action.
        ///     IN fun_name: []const u8 - The function name to act on.
        ///     IN RetType: type        - The return type of the function being mocked.
        ///     IN params: arglist      - The list of parameters of the mocked function.
        ///
        /// Return: RetType
        ///     The return value of the mocked function. This can be void.
        ///
        pub fn performAction(self: *Self, comptime fun_name: []const u8, comptime RetType: type, params: ...) RetType {
            if (self.named_actions.get(fun_name)) |kv_actions_list| {
                var action_list = kv_actions_list.value;
                // Peak the first action to test the action type
                if (action_list.first) |action_node| {
                    const action = action_node.data;
                    const ret = switch (action.action) {
                        ActionType.TestValue => ret: {
                            comptime var i = 0;
                            inline while (i < params.len) : (i += 1) {
                                // Now pop the action as we are going to use it
                                // Have already checked that it is not null
                                const test_node = action_list.popFirst().?;
                                const test_action = test_node.data;
                                const param = params[i];
                                const param_type = @typeOf(params[i]);

                                expectTest(param_type, param, test_action.data);

                                // Free the node
                                action_list.destroyNode(test_node, GlobalAllocator);
                            }
                            break :ret expectGetValue(fun_name, &action_list, RetType);
                        },
                        ActionType.ConsumeFunctionCall => ret: {
                            // Now pop the action as we are going to use it
                            // Have already checked that it is not null
                            const test_node = action_list.popFirst().?;
                            const test_element = test_node.data.data;

                            // Work out the type of the function to call from the params and return type
                            // At compile time
                            //const expected_function = getFunctionType(RetType, params);
                            // Waiting for this:
                            // error: compiler bug: unable to call var args function at compile time. https://github.com/ziglang/zig/issues/313
                            // to be resolved
                            const expected_function = switch (params.len) {
                                0 => fn () RetType,
                                1 => fn (@typeOf(params[0])) RetType,
                                2 => fn (@typeOf(params[0]), @typeOf(params[1])) RetType,
                                else => @compileError("Couldn't generate function type for " ++ params.len ++ "parameters\n"),
                            };

                            // Get the corresponding DataElementType
                            const expect_type = comptime getDataElementType(expected_function);

                            // Test that the types match
                            expectEqual(expect_type, @as(DataElementType, test_element));

                            // Types match, so can use the expected type to get the actual data
                            const actual_function = getDataValue(expected_function, test_element);

                            // Free the node
                            action_list.destroyNode(test_node, GlobalAllocator);

                            // The data element will contain the function to call
                            const r = switch (params.len) {
                                0 => @noInlineCall(actual_function),
                                1 => @noInlineCall(actual_function, params[0]),
                                2 => @noInlineCall(actual_function, params[0], params[1]),
                                else => @compileError(params.len ++ " or more parameters not supported"),
                            };

                            break :ret r;
                        },
                        ActionType.RepeatFunctionCall => ret: {
                            // Do the same for ActionType.ConsumeFunctionCall but instead of
                            // popping the function, just peak
                            const test_element = action.data;
                            const expected_function = switch (params.len) {
                                0 => fn () RetType,
                                1 => fn (@typeOf(params[0])) RetType,
                                2 => fn (@typeOf(params[0]), @typeOf(params[1])) RetType,
                                else => @compileError("Couldn't generate function type for " ++ params.len ++ "parameters\n"),
                            };

                            // Get the corresponding DataElementType
                            const expect_type = comptime getDataElementType(expected_function);

                            // Test that the types match
                            expectEqual(expect_type, @as(DataElementType, test_element));

                            // Types match, so can use the expected type to get the actual data
                            const actual_function = getDataValue(expected_function, test_element);

                            // The data element will contain the function to call
                            const r = switch (params.len) {
                                0 => @noInlineCall(actual_function),
                                1 => @noInlineCall(actual_function, params[0]),
                                2 => @noInlineCall(actual_function, params[0], params[1]),
                                else => @compileError(params.len ++ " or more parameters not supported"),
                            };

                            break :ret r;
                        },
                    };

                    // Re-assign the action list as this would have changed
                    kv_actions_list.value = action_list;
                    return ret;
                } else {
                    std.debug.panic("No action list elements for function: " ++ fun_name ++ "\n");
                }
            } else {
                std.debug.panic("No function name: " ++ fun_name ++ "\n");
            }
        }

        ///
        /// Initialise the mocking framework.
        ///
        /// Return: Self
        ///     An initialised mocking framework.
        ///
        pub fn init() Self {
            return Self{
                .named_actions = StringHashMap(ActionList).init(GlobalAllocator),
            };
        }

        ///
        /// End the mocking session. This will check all test parameters and consume functions are
        /// consumed. Any repeat functions are deinit.
        ///
        /// Arguments:
        ///     IN/OUT self: *Self - Self. This is the mocking object to be modified to finished
        ///                          the mocking session.
        ///
        pub fn finish(self: *Self) void {
            // Make sure the expected list is empty
            var it = self.named_actions.iterator();
            while (it.next()) |next| {
                var action_list = next.value;
                if (action_list.popFirst()) |action_node| {
                    const action = action_node.data;
                    switch (action.action) {
                        ActionType.TestValue, ActionType.ConsumeFunctionCall => {
                            // These need to be all consumed
                            std.debug.panic("Unused testing value: Type: {}, value: {} for function '{}'\n", action.action, @as(DataElementType, action.data), next.key);
                        },
                        ActionType.RepeatFunctionCall => {
                            // As this is a repeat action, the function will still be here
                            // So need to free it
                            action_list.destroyNode(action_node, GlobalAllocator);
                            next.value = action_list;
                        },
                    }
                }
            }

            // Free the function mapping
            self.named_actions.deinit();
        }
    };
}

/// The global mocking object that is used for a mocking session. Maybe in the future, we can have
/// local mocking objects so can run the tests in parallel.
var mock: ?Mock() = null;

///
/// Get the mocking object and check we have one initialised.
///
/// Return: *Mock()
///     Pointer to the global mocking object so can be modified.
///
fn getMockObject() *Mock() {
    // Make sure we have a mock object
    if (mock) |*m| {
        return m;
    } else {
        warn("MOCK object doesn't exists, please initiate this test\n");
        expect(false);
        unreachable;
    }
}

///
/// Initialise the mocking framework.
///
pub fn initTest() void {
    // Make sure there isn't a mock object
    if (mock) |_| {
        warn("MOCK object already exists, please free previous test\n");
        expect(false);
        unreachable;
    } else {
        mock = Mock().init();
    }
}

///
/// End the mocking session. This will check all test parameters and consume functions are
/// consumed. Any repeat functions are deinit.
///
pub fn freeTest() void {
    getMockObject().finish();

    // This will stop double frees
    mock = null;
}

///
/// Add a list of test parameters to the action list. This will create a list of data
/// elements that represent the list of parameters that will be passed to a mocked
/// function. A mocked function may be called multiple times, so this list may contain
/// multiple values for each call to the same mocked function.
///
/// Arguments:
///     IN/OUT self: *Self      - Self. This is the mocking object to be modified to add
///                               the test parameters.
///     IN fun_name: []const u8 - The function name to add the test parameters to.
///     IN params: arglist      - The parameters to add.
///
pub fn addTestParams(comptime fun_name: []const u8, params: ...) void {
    var mock_obj = getMockObject();
    comptime var i = 0;
    inline while (i < params.len) : (i += 1) {
        mock_obj.addAction(fun_name, params[i], ActionType.TestValue);
    }
}

///
/// Add a function to mock out another. This will add a consume function action, so once
/// the mocked function is called, this action wil be removed.
///
/// Arguments:
///     IN fun_name: []const u8 - The function name to add the function to.
///     IN function: var        - The function to add.
///
pub fn addConsumeFunction(comptime fun_name: []const u8, function: var) void {
    getMockObject().addAction(fun_name, function, ActionType.ConsumeFunctionCall);
}

///
/// Add a function to mock out another. This will add a repeat function action, so once
/// the mocked function is called, this action wil be removed.
///
/// Arguments:
///     IN fun_name: []const u8 - The function name to add the function to.
///     IN function: var        - The function to add.
///
pub fn addRepeatFunction(comptime fun_name: []const u8, function: var) void {
    getMockObject().addAction(fun_name, function, ActionType.RepeatFunctionCall);
}

///
/// Perform an action on a function. This can be one of ActionType.
///
/// Arguments:
///     IN fun_name: []const u8 - The function name to act on.
///     IN RetType: type        - The return type of the function being mocked.
///     IN params: arglist      - The list of parameters of the mocked function.
///
/// Return: RetType
///     The return value of the mocked function. This can be void.
///
pub fn performAction(comptime fun_name: []const u8, comptime RetType: type, params: ...) RetType {
    return getMockObject().performAction(fun_name, RetType, params);
}

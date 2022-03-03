const std = @import("std");
const StringHashMap = std.StringHashMap;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const GlobalAllocator = std.testing.allocator;
const TailQueue = std.TailQueue;
////Imports////
///
/// The enumeration of types that the mocking framework supports. These include basic types like u8
/// and function types like fn () void.
///
////DataElementType////
///
/// A tagged union of all the data elements that the mocking framework can work with. This can be
/// expanded to add new types. This is needed as need a list of data that all have different types,
/// so this wraps the data into a union, (which is of one type) so can have a list of them.
/// When https://github.com/ziglang/zig/issues/383 and https://github.com/ziglang/zig/issues/2907
/// is done, can programitaclly create types for this. Can use a compile time block that loops
/// through the available basic types and create function types so don't have a long list.
///
////DataElement////
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
        ///     IN arg: anytype - The data, this can be a function or basic type value.
        ///
        /// Return: DataElement
        ///     A DataElement with the data wrapped.
        ///
        fn createDataElement(arg: anytype) DataElement {
            return switch (@TypeOf(arg)) {
                ////createDataElement////
            };
        }

        ///
        /// Get the enum that represents the type given.
        ///
        /// Arguments:
        ///     IN comptime T: type - A type.
        ///
        /// Return: DataElementType
        ///     The DataElementType that represents the type given.
        ///
        fn getDataElementType(comptime T: type) DataElementType {
            return switch (T) {
                ////getDataElementType////
            };
        }

        ///
        /// Get the data out of the tagged union
        ///
        /// Arguments:
        ///     IN comptime T: type     - The type of the data to extract. Used to switch on the
        ///                               tagged union.
        ///     IN element: DataElement - The data element to unwrap the data from.
        ///
        /// Return: T
        ///     The data of type T from the DataElement.
        ///
        fn getDataValue(comptime T: type, element: DataElement) T {
            return switch (T) {
                ////getDataValue////
            };
        }

        ///
        /// Create a function type from a return type and its arguments.
        ///
        /// Arguments:
        ///     IN comptime RetType: type - The return type of the function.
        ///     IN params: type           - The parameters of the function. This will be the type
        ///                                 of a anonymous struct to get the fields and types.
        ///
        /// Return: type
        ///     A function type that represents the return type and its arguments.
        ///
        fn getFunctionType(comptime RetType: type, params: type) type {
            const fields = @typeInfo(params).Struct.fields;
            return switch (fields.len) {
                0 => fn () RetType,
                1 => fn (fields[0].field_type) RetType,
                2 => fn (fields[0].field_type, fields[1].field_type) RetType,
                3 => fn (fields[0].field_type, fields[1].field_type, fields[2].field_type) RetType,
                4 => fn (fields[0].field_type, fields[1].field_type, fields[2].field_type, fields[3].field_type) RetType,
                else => @compileError("More than 3 parameters not supported"),
            };
        }

        ///
        /// Call a function with the function definitions and parameters.
        ///
        /// Argument:
        ///     IN comptime RetType: type - The return type of the function.
        ///     IN function_type: anytype - The function pointer to call.
        ///     IN params: anytype        - The parameter(s) of the function.
        ///
        /// Return: RetType
        ///     The return value of the called function. This can be void.
        ///
        fn callFunction(comptime RetType: type, function_type: anytype, params: anytype) RetType {
            return switch (params.len) {
                0 => function_type(),
                1 => function_type(params[0]),
                2 => function_type(params[0], params[1]),
                3 => function_type(params[0], params[1], params[2]),
                4 => function_type(params[0], params[1], params[2], params[3]),
                // Should get to this as `getFunctionType` will catch this
                else => @compileError("More than 3 parameters not supported"),
            };
        }

        ///
        /// Perform a generic function action. This can be part of a ConsumeFunctionCall or
        /// RepeatFunctionCall action. This will perform the function type comparison and
        /// call the function stored in the action list.
        ///
        /// Argument:
        ///     IN comptime RetType: type    - The return type of the function to call.
        ///     IN test_element: DataElement - The test value to compare to the generated function
        ///                                    type. This is also the function that will be called.
        ///     IN params: anytype           - The parameters of the function to call.
        ///
        /// Return: RetType
        ///     The return value of the called function. This can be void.
        ///
        fn performGenericFunction(comptime RetType: type, test_element: DataElement, params: anytype) RetType {
            // Get the expected function type
            const expected_function = getFunctionType(RetType, @TypeOf(params));

            // Test that the types match
            const expect_type = comptime getDataElementType(expected_function);
            expectEqual(expect_type, @as(DataElementType, test_element)) catch @panic("Function type is not as expected\n");

            // Types match, so can use the expected type to get the actual data
            const actual_function = getDataValue(expected_function, test_element);
            return callFunction(RetType, actual_function, params);
        }

        ///
        /// This tests a value passed to a function.
        ///
        /// Arguments:
        ///     IN comptime ExpectedType: type  - The expected type of the value to be tested.
        ///     IN expected_value: ExpectedType - The expected value to be tested. This is what was
        ///                                       passed to the functions.
        ///     IN elem: DataElement            - The wrapped data element to test against the
        ///                                       expected value.
        ///
        fn expectTest(comptime ExpectedType: type, expected_value: ExpectedType, elem: DataElement) void {
            if (ExpectedType == void) {
                // Can't test void as it has no value
                std.debug.panic("Can not test a value for void\n", .{});
            }

            // Test that the types match
            const expect_type = comptime getDataElementType(ExpectedType);
            expectEqual(expect_type, @as(DataElementType, elem)) catch std.debug.panic("Expected {}, got {}\n", .{ expect_type, @as(DataElementType, elem) });

            // Types match, so can use the expected type to get the actual data
            const actual_value = getDataValue(ExpectedType, elem);

            // Test the values
            expectEqual(expected_value, actual_value) catch std.debug.panic("Expected {}, got {}\n", .{ expected_value, actual_value });
        }

        ///
        /// This returns a value from the wrapped data element. This will be a test value to be
        /// returned by a mocked function.
        ///
        /// Arguments:
        ///     IN comptime fun_name: []const u8 - The function name to be used to tell the user if
        ///                                        there is no return value set up.
        ///     IN/OUT action_list: *ActionList  - The action list to extract the return value from.
        ///     IN comptime  DataType: type      - The type of the return value.
        ///
        /// Return: RetType
        ///     The return value of the expected value.
        ///
        fn expectGetValue(comptime fun_name: []const u8, action_list: *ActionList, comptime DataType: type) DataType {
            if (DataType == void) {
                return;
            }

            if (action_list.*.popFirst()) |action_node| {
                // Free the node
                defer GlobalAllocator.destroy(action_node);

                const action = action_node.data;

                // Test that the data match
                const expect_data = comptime getDataElementType(DataType);
                expectEqual(expect_data, @as(DataElementType, action.data)) catch std.debug.panic("Expected {}, got {}\n", .{ expect_data, action.data });
                return getDataValue(DataType, action.data);
            } else {
                std.debug.panic("No more test values for the return of function: " ++ fun_name ++ "\n", .{});
            }
        }

        ///
        /// This adds a action to the action list with ActionType provided. It will create a new
        /// mapping if one doesn't exist for a function name.
        ///
        /// Arguments:
        ///     IN/OUT self: *Self               - Self. This is the mocking object to be modified
        ///                                        to add the test data.
        ///     IN comptime fun_name: []const u8 - The function name to add the test data to.
        ///     IN data: anytype                 - The data to add to the action for the function.
        ///     IN action_type: ActionType       - The action type to add.
        ///
        pub fn addAction(self: *Self, comptime fun_name: []const u8, data: anytype, action_type: ActionType) void {
            // Add a new mapping if one doesn't exist.
            if (!self.named_actions.contains(fun_name)) {
                self.named_actions.put(fun_name, .{}) catch unreachable;
            }

            // Get the function mapping to add the parameter to.
            if (self.named_actions.getEntry(fun_name)) |actions_kv| {
                // Take a reference of the value so the underlying action list will update
                var action_list = &actions_kv.value_ptr;
                const action = Action{
                    .action = action_type,
                    .data = createDataElement(data),
                };
                var a = GlobalAllocator.create(TailQueue(Action).Node) catch unreachable;
                a.* = .{ .data = action };
                action_list.*.append(a);
            } else {
                // Shouldn't get here as we would have just added a new mapping
                // But just in case ;)
                std.debug.panic("No function name: " ++ fun_name ++ "\n", .{});
            }
        }

        ///
        /// Perform an action on a function. This can be one of ActionType.
        ///
        /// Arguments:
        ///     IN/OUT self: *Self               - Self. This is the mocking object to be modified
        ///                                        to perform a action.
        ///     IN comptime fun_name: []const u8 - The function name to act on.
        ///     IN comptime RetType: type        - The return type of the function being mocked.
        ///     IN params: anytype               - The list of parameters of the mocked function.
        ///
        /// Return: RetType
        ///     The return value of the mocked function. This can be void.
        ///
        pub fn performAction(self: *Self, comptime fun_name: []const u8, comptime RetType: type, params: anytype) RetType {
            if (self.named_actions.getEntry(fun_name)) |kv_actions_list| {
                // Take a reference of the value so the underlying action list will update
                var action_list = &kv_actions_list.value_ptr;
                // Peak the first action to test the action type
                if (action_list.*.first) |action_node| {
                    const action = action_node.data;
                    return switch (action.action) {
                        ActionType.TestValue => ret: {
                            comptime var i = 0;
                            inline while (i < params.len) : (i += 1) {
                                // Now pop the action as we are going to use it
                                // Have already checked that it is not null
                                const test_node = action_list.*.popFirst().?;
                                defer GlobalAllocator.destroy(test_node);

                                const test_action = test_node.data;
                                const param = params[i];
                                const param_type = @TypeOf(params[i]);

                                expectTest(param_type, param, test_action.data);
                            }
                            break :ret expectGetValue(fun_name, action_list.*, RetType);
                        },
                        ActionType.ConsumeFunctionCall => ret: {
                            // Now pop the action as we are going to use it
                            // Have already checked that it is not null
                            const test_node = action_list.*.popFirst().?;
                            // Free the node once done
                            defer GlobalAllocator.destroy(test_node);
                            const test_element = test_node.data.data;

                            break :ret performGenericFunction(RetType, test_element, params);
                        },
                        ActionType.RepeatFunctionCall => ret: {
                            // Do the same for ActionType.ConsumeFunctionCall but instead of
                            // popping the function, just peak
                            const test_element = action.data;
                            break :ret performGenericFunction(RetType, test_element, params);
                        },
                    };
                } else {
                    std.debug.panic("No action list elements for function: " ++ fun_name ++ "\n", .{});
                }
            } else {
                std.debug.panic("No function name: " ++ fun_name ++ "\n", .{});
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
                // Take a reference so the underlying action list will be updated.
                var action_list = &next.value_ptr;
                if (action_list.*.popFirst()) |action_node| {
                    const action = action_node.data;
                    switch (action.action) {
                        ActionType.TestValue, ActionType.ConsumeFunctionCall => {
                            // These need to be all consumed
                            std.debug.panic("Unused testing value: Type: {}, value: {} for function '{s}'\n", .{ action.action, @as(DataElementType, action.data), next.key_ptr.* });
                        },
                        ActionType.RepeatFunctionCall => {
                            // As this is a repeat action, the function will still be here
                            // So need to free it
                            GlobalAllocator.destroy(action_node);
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
        std.debug.panic("MOCK object doesn't exists, please initialise this test\n", .{});
    }
}

///
/// Initialise the mocking framework.
///
pub fn initTest() void {
    // Make sure there isn't a mock object
    if (mock) |_| {
        std.debug.panic("MOCK object already exists, please free previous test\n", .{});
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
///     IN comptime fun_name: []const u8 - The function name to add the test parameters to.
///     IN params: anytype               - The parameters to add.
///
pub fn addTestParams(comptime fun_name: []const u8, params: anytype) void {
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
///     IN comptime fun_name: []const u8 - The function name to add the function to.
///     IN function: anytype             - The function to add.
///
pub fn addConsumeFunction(comptime fun_name: []const u8, function: anytype) void {
    getMockObject().addAction(fun_name, function, ActionType.ConsumeFunctionCall);
}

///
/// Add a function to mock out another. This will add a repeat function action, so once
/// the mocked function is called, this action wil be removed.
///
/// Arguments:
///     IN comptime fun_name: []const u8 - The function name to add the function to.
///     IN function: anytype             - The function to add.
///
pub fn addRepeatFunction(comptime fun_name: []const u8, function: anytype) void {
    getMockObject().addAction(fun_name, function, ActionType.RepeatFunctionCall);
}

///
/// Perform an action on a function. This can be one of ActionType.
///
/// Arguments:
///     IN comptime fun_name: []const u8 - The function name to act on.
///     IN comptime RetType: type        - The return type of the function being mocked.
///     IN params: anytype               - The list of parameters of the mocked function.
///
/// Return: RetType
///     The return value of the mocked function. This can be void.
///
pub fn performAction(comptime fun_name: []const u8, comptime RetType: type, params: anytype) RetType {
    return getMockObject().performAction(fun_name, RetType, params);
}

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Oom = Allocator.Error;

pub fn AutoSorted(T: type) type {
    return Sorted(T, AutoContext(T));
}

pub fn AutoContext(comptime T: type) type {
    return struct {
        pub const compare = getAutoCompareFn(T, @This());
    };
}

pub fn getAutoCompareFn(T: type, Context: type) (fn (Context, T, T) std.math.Order) {
    return struct {
        fn compare(ctx: Context, a: T, b: T) std.math.Order {
            _ = ctx;
            return std.math.order(a, b);
        }
    }.compare;
}

pub fn Sorted(T: type, Context: type) type {
    return struct {
        items: []const T,

        pub const Self = @This();

        pub const empty: Self = .{
            .items = &.{},
        };

        pub fn clone(self: Self, gpa: Allocator) Oom!Self {
            return .{ .items = try gpa.dupe(T, self.items) };
        }

        const SortAdapter = struct {
            ctx: Context,

            fn lessThan(adt: SortAdapter, lhs: T, rhs: T) bool {
                return adt.ctx.compare(lhs, rhs) == .lt;
            }
        };

        pub fn initUnsorted(items: []T) Self {
            if (@sizeOf(Context) != 0) {
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call initUnsortedContext instead.");
            }

            return initUnsortedContext(items, undefined);
        }

        pub fn initUnsortedContext(items: []T, ctx: Context) Self {
            std.mem.sort(
                T,
                items,
                SortAdapter{ .ctx = ctx },
                SortAdapter.lessThan,
            );
            return .{ .items = items };
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.items);
            self.* = undefined;
        }

        // TODO: Use context to determine equality instead.
        pub fn eql(self: Self, other: Self) bool {
            return std.mem.eql(T, self.items, other.items);
        }

        pub const SearchResult = union(enum) {
            /// If the value exists. This is its index.
            exists: usize,
            /// If the value doesn't exist. This is where it would exist.
            future: usize,
        };

        pub fn search(self: Self, value: T) SearchResult {
            if (@sizeOf(Context) != 0) {
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call searchContext instead.");
            }

            return self.searchContext(self, value, undefined);
        }

        const Adapter = struct {
            ctx: Context,
            lhs: T,

            pub fn compare(adt: Adapter, rhs: T) std.math.Order {
                return adt.ctx.compare(adt.lhs, rhs);
            }
        };

        pub fn searchContext(self: Self, value: T, ctx: Context) SearchResult {
            const result = std.sort.upperBound(T, self.items, Adapter{ .lhs = value, .ctx = ctx }, Adapter.compare);
            if (result > 0 and
                ctx.compare(value, self.items[result - 1]) == .eq)
            {
                return .{ .exists = result - 1 };
            }

            return .{ .future = result };
        }

        pub fn contains(self: Self, value: T) bool {
            if (@sizeOf(Context) != 0) {
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call containsContext instead.");
            }
            return self.containsContext(value, undefined);
        }

        pub fn containsContext(self: Self, value: T, ctx: Context) bool {
            return switch (self.searchContext(value, ctx)) {
                .exists => true,
                .future => false,
            };
        }

        // pub fn add(self: Self, gpa: Allocator, value: T) Oom!Self {
        //     if (@sizeOf(Context) != 0) {
        //         @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call addContext instead.");
        //     }
        //     return self.addContext(gpa, value, undefined);
        // }

        // pub fn addContext(self: Self, gpa: Allocator, value: T, ctx: Context) Oom!Self {
        //     return switch(self.searchContext(value, ctx)) {
        //         .future => |index| {
        //             const new_items = try gpa.alloc(T, self.items.len + 1);
        //             insert(new_items, self.items, index, value);

        //             return .{.items = new_items};
        //         },
        //         .exists => .{.items = try gpa.dupe(T, self.items)},
        //     };
        // }

        pub fn add(self: Self, gpa: Allocator, value: T) Oom!Self {
            if (@sizeOf(Context) != 0) {
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call addContext instead.");
            }
            return self.addContext(gpa, value, undefined);
        }

        pub fn addContext(self: Self, gpa: Allocator, value: T, ctx: Context) Oom!Self {
            // Asserts that the current element doesn't exist.
            const index = self.searchContext(value, ctx).future;

            const items = try gpa.alloc(T, self.items.len + 1);
            @memcpy(items[0..index], self.items[0..index]);
            @memcpy(items[index + 1 ..], self.items[index..]);
            items[index] = value;

            return .{ .items = items };
        }

        pub fn remove(self: Self, gpa: Allocator, value: T) Oom!Self {
            if (@sizeOf(Context) != 0) {
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call removeContext instead.");
            }

            return self.removeContext(gpa, value, undefined);
        }

        pub fn removeContext(self: Self, gpa: Allocator, value: T, ctx: Context) Oom!Self {
            // Asserts that `value` exists
            const index = self.searchContext(value, ctx).exists;

            const items = try gpa.alloc(T, self.items.len - 1);
            @memcpy(items[0..index], self.items[0..index]);
            @memcpy(items[index..], self.items[index + 1 ..]);

            return .{ .items = items };
        }
    };
}

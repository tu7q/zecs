const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Oom = Allocator.Error;

const set = @import("set.zig");

// https://github.com/ziglang/zig/issues/19858#issuecomment-2369861301
const TypeId = *const struct {
    _: u8,
};

pub inline fn typeId(comptime T: type) TypeId {
    return &struct {
        comptime {
            _ = T;
        }
        var id: @typeInfo(TypeId).pointer.child = undefined;
    }.id;
}

pub const ArchetypeIndex = enum(u32) { _ };
pub const Archetype = set.Sorted(ComponentId, struct {
    pub fn compare(_: @This(), a: ComponentId, b: ComponentId) std.math.Order {
        return std.math.order(@intFromEnum(a), @intFromEnum(b));
    }
});
pub const ArchetypeManaged = set.AutoSortedManaged(ComponentId);
pub const ArchetypeContext = struct {
    pub fn eql(ctx: ArchetypeContext, a: Archetype, b: Archetype, _: usize) bool {
        _ = ctx;
        return a.eql(b);
    }

    pub fn hash(ctx: ArchetypeContext, arch: Archetype) u32 {
        _ = ctx;
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHashStrat(&hasher, arch.items, .Deep);

        return @truncate(hasher.final());
    }
};

pub const EntityIndex = u27;
pub const EntityGeneration = u5;

pub const EntityId = packed struct {
    idx: EntityIndex,
    gen: EntityGeneration,
};

const EntityLocation = struct {
    aid: ArchetypeIndex,
    row: u32,
};

pub const ComponentId = enum(usize) {
    _,

    pub fn order(a: ComponentId, b: ComponentId) std.math.Order {
        return std.math.order(@intFromEnum(a), @intFromEnum(b));
    }
};

pub const ComponentDescriptor = struct {
    name: []const u8,
    alignment: std.mem.Alignment,
    size: usize,

    pub fn of(T: type) ComponentDescriptor {
        return .{
            .name = @typeName(T),
            .alignment = .of(T),
            .size = @sizeOf(T),
        };
    }
};

pub const Column = struct {
    data: [*]u8,
    len: usize,
    byte_capacity: usize,

    // Can we avoid storing this without ruining things..
    item_size: usize,
    item_alignment: std.mem.Alignment,

    pub fn initDescriptor(descriptor: ComponentDescriptor) Column {
        return .{
            .data = undefined,
            .len = 0,
            .byte_capacity = 0,
            .item_size = descriptor.size,
            .item_alignment = descriptor.alignment,
        };
    }

    pub fn deinit(column: *Column, gpa: Allocator) void {
        alignedFree(gpa, column.item_alignment, column.allocatedBytes());
        column.* = undefined;
    }

    pub fn allocatedBytes(column: *Column) []u8 {
        return column.data[0..column.byte_capacity];
    }

    pub fn ensureTotalByteCapacity(column: *Column, gpa: Allocator, new_byte_capacity: usize) Oom!void {
        if (column.byte_capacity >= new_byte_capacity) return;
        return column.ensureTotalByteCapacityPrecise(gpa, growCapacity(column.byte_capacity, new_byte_capacity));
    }

    pub fn ensureTotalByteCapacityPrecise(column: *Column, gpa: Allocator, new_byte_capacity: usize) Oom!void {
        if (column.item_size == 0) {
            column.byte_capacity = std.math.maxInt(usize);
            return;
        }

        if (column.byte_capacity >= new_byte_capacity) return;

        const old_memory = column.allocatedBytes();
        if (alignedRemap(gpa, old_memory, column.item_alignment, new_byte_capacity)) |new_memory| {
            column.data = new_memory.ptr;
            column.byte_capacity = new_memory.len;
        } else {
            const new_memory = try alignedAlloc(gpa, column.item_alignment, new_byte_capacity);
            @memcpy(new_memory[0 .. column.len * column.item_size], column.data);
            alignedFree(gpa, column.item_alignment, old_memory);
            column.data = new_memory.ptr;
            column.byte_capacity = new_memory.len;
        }
    }

    pub fn swapRemove(column: *Column, row: usize) void {
        // Asserts that the column is not empty.
        const last_index = column.len - 1;

        if (row == last_index) {
            @memset(column.getItemSlot(row), undefined);
            column.len -= 1;
            return;
        }

        // Swap the last index to where row is.
        @memcpy(column.getItemSlot(row), column.getItemSlot(last_index));
        @memset(column.getItemSlot(last_index), undefined);
        column.len -= 1;
    }

    pub fn append(column: *Column, gpa: Allocator, item: []const u8) Oom!void {
        const new_item_slot = try column.addOne(gpa);
        @memcpy(new_item_slot, item);
    }

    pub fn addOne(column: *Column, gpa: Allocator) Oom![]u8 {
        const new_byte_len = (1 + column.len) * column.item_size;
        try column.ensureTotalByteCapacity(gpa, new_byte_len);
        return column.addOneAssumeCapacity();
    }

    pub fn addOneAssumeCapacity(column: *Column) Oom![]u8 {
        assert(column.len * column.item_size < column.byte_capacity);

        column.len += 1;
        const slot_start = column.len * column.item_size;
        return column.data[slot_start..][0..column.item_size];
    }

    pub fn getItemPtr(column: Column, index: usize) *anyopaque {
        const slot = column.getItemSlot(index);
        return @ptrCast(slot.ptr);
    }

    pub fn getItemSlot(column: Column, index: usize) []u8 {
        const offset = column.item_size * index;
        return column.data[offset..][0..column.item_size];
    }

    const init_capacity = @as(comptime_int, 256);

    fn growCapacity(current: usize, minimum: usize) usize {
        var new = current;
        while (true) {
            new +|= new / 2 + init_capacity;
            if (new >= minimum)
                return new;
        }
    }
};

fn alignedFree(gpa: Allocator, alignment: std.mem.Alignment, allocation: []u8) void {
    switch (alignment) {
        inline else => |al| gpa.free(@as([]align(al.toByteUnits()) u8, @ptrCast(@alignCast(allocation)))),
        _ => @panic("Non power of 2 alignment"),
    }
}

fn alignedAlloc(gpa: Allocator, alignment: std.mem.Alignment, n: usize) Oom![]u8 {
    return switch (alignment) {
        inline else => |al| gpa.alignedAlloc(u8, al, n),
        _ => @panic("Non power of 2 alignment"),
    };
}

fn alignedRemap(gpa: Allocator, allocation: []u8, alignment: std.mem.Alignment, new_len: usize) ?[]u8 {
    return switch (alignment) {
        inline else => |al| gpa.remap(@as([]align(al.toByteUnits()) u8, @ptrCast(@alignCast(allocation))), new_len),
        _ => @panic("Non power of 2 alignment"),
    };
}

pub const Table = struct {
    count: usize = 0,
    // Safety check. The ComponentId should have been
    // inserted in sorted order.
    components: std.AutoArrayHashMapUnmanaged(ComponentId, Column),
    entity_ids: std.ArrayList(EntityId),

    pub const empty: Table = .{
        .count = 0,
        .components = .empty,
        .entity_ids = .empty,
    };

    // Copies an entity from the src table into the dst table.
    // Asserts that the dst table is a superset of the current table.
    // The new row of the copied entity in dst will be at
    // dst.count - 1
    pub fn copy(dst: *Table, gpa: Allocator, src: *Table, row: usize) Oom!void {
        const entity_id = src.entity_ids.items[row];

        // Ensure that the destination table has
        // enough memory to store a new row.
        try dst.addOne(gpa, entity_id);

        for (src.components.keys(), src.components.values()) |cid, src_col| {
            const dst_col = dst.getColumnPtr(cid) orelse continue;

            // Copy the data into the slot.
            @memcpy(dst_col.getItemSlot(dst.count - 1), src_col.getItemSlot(row));
        }
    }

    // TODO: It may be possible to specify fields to insert by
    //       if we maintain ComponentId insertion order.
    pub fn addOne(table: *Table, gpa: Allocator, entity_id: EntityId) Oom!void {
        try table.entity_ids.append(gpa, entity_id);
        errdefer _ = table.entity_ids.pop();

        for (table.components.values()) |*column| {
            const slot = try column.addOne(gpa);
            @memset(slot, undefined);
        }

        table.count += 1;
    }

    pub fn swapRemove(table: *Table, row: usize) void {
        assert(row < table.count);

        _ = table.entity_ids.swapRemove(row);
        for (table.components.values()) |*column| {
            column.swapRemove(row);
        }

        table.count -= 1;
    }

    pub fn deinit(table: *Table, gpa: Allocator) void {
        for (table.components.values()) |*column| {
            column.deinit(gpa);
        }
        table.components.deinit(gpa);
        table.entity_ids.deinit(gpa);
        table.* = undefined;
    }

    pub fn getColumnPtr(table: Table, cid: ComponentId) ?*Column {
        return table.components.getPtr(cid);
    }

    pub fn getColumn(table: Table, component_id: ComponentId) ?Column {
        return table.components.get(component_id);
    }
};

pub const Tables = struct {
    /// A mapping from TypeId to ComponentId.
    type_to_component: std.AutoArrayHashMapUnmanaged(TypeId, ComponentId),
    /// Mapping of component id to component descriptors.
    components: std.ArrayList(ComponentDescriptor),
    /// The next free entry into the entities list.
    next_free_entry: ?EntityIndex = null,
    /// List of entities.
    entities: std.ArrayList(Node),
    /// Mapping from archetypes to tables.
    /// Note: order is maintained by only inserting.
    tables: std.ArrayHashMapUnmanaged(Archetype, Table, ArchetypeContext, true),

    // TODO: Optimize the size of this Node.
    pub const Node = struct {
        egen: EntityGeneration,
        data: union {
            eloc: EntityLocation,
            next: ?EntityIndex,

            pub fn gen(self: *@This()) EntityGeneration {
                const node: *Node = @fieldParentPtr("data", self);
                return node.egen;
            }
        },
    };

    pub const empty: Tables = .{
        .type_to_component = .empty,
        .components = .empty,
        .next_free_entry = null,
        .entities = .empty,
        .tables = .empty,
    };

    /// Free the memory associated with `self`.
    pub fn deinit(self: *Tables, gpa: Allocator) void {
        self.type_to_component.deinit(gpa);
        self.components.deinit(gpa);
        for (self.tables.keys(), self.tables.values()) |*arch, *table| {
            arch.deinit(gpa);
            table.deinit(gpa);
        }
        self.tables.deinit(gpa);
        self.entities.deinit(gpa);
        self.* = undefined;
    }

    /// Register a component with `self`.
    pub fn registerComponent(self: *Tables, gpa: Allocator, C: type) Oom!ComponentId {
        const type_entry = try self.type_to_component.getOrPut(gpa, typeId(C));
        errdefer _ = self.type_to_component.swapRemove(typeId(C));

        if (type_entry.found_existing) return type_entry.value_ptr.*;

        const component_id = try self.rawRegisterComponent(gpa, .of(C));
        type_entry.value_ptr.* = component_id;

        return component_id;
    }

    fn rawRegisterComponent(self: *Tables, gpa: Allocator, descriptor: ComponentDescriptor) Oom!ComponentId {
        try self.components.append(gpa, descriptor);
        return @enumFromInt(self.components.items.len - 1);
    }

    fn getComponentId(self: Tables, C: type) ?ComponentId {
        return self.type_to_component.get(typeId(C));
    }

    fn prepareNextEntitySlot(
        self: *Tables,
        gpa: Allocator,
        eloc: EntityLocation,
    ) Oom!EntityId {
        const index: u27 = if (self.next_free_entry) |entry| entry else blk: {
            try self.entities.append(gpa, .{
                .egen = 0,
                .data = undefined,
            });
            break :blk @intCast(self.entities.items.len - 1);
        };

        const slots = self.entities.items;
        slots[index].data = .{ .eloc = eloc };

        return .{ .idx = index, .gen = slots[index].egen };
    }

    fn freeEntitySlot(self: *Tables, index: EntityIndex) void {
        const data = &self.entities.items[index].data;

        data.* = .{ .next = self.next_free_entry };
        self.next_free_entry = index;
    }

    fn initTable(
        self: *Tables,
        gpa: Allocator,
        archetype: Archetype,
        table: *Table,
    ) Oom!void {
        table.* = .empty;
        errdefer table.deinit(gpa);

        try table.components.ensureTotalCapacity(gpa, archetype.items.len);

        for (archetype.items) |cid| {
            const descriptor = self.components.items[@intFromEnum(cid)];
            table.components.putNoClobber(gpa, cid, .initDescriptor(descriptor)) catch unreachable;
        }
    }

    fn ensureUnownedArchetypeExists(
        self: *Tables,
        gpa: Allocator,
        archetype: Archetype,
    ) Oom!ArchetypeIndex {
        const entry = try self.tables.getOrPut(gpa, archetype);

        if (!entry.found_existing) {
            // Ordered remove to ensure that
            // ArchetypeIndex isn't mucked up.
            errdefer _ = self.tables.orderedRemove(archetype);

            entry.key_ptr.* = try archetype.clone(gpa);
            try self.initTable(gpa, archetype, entry.value_ptr);
        }

        return @enumFromInt(entry.index);
    }

    // Takes ownership of the archetype passed in.
    fn ensureArchetypeExists(
        self: *Tables,
        gpa: Allocator,
        archetype: Archetype,
    ) Oom!ArchetypeIndex {
        const entry = self.tables.getOrPut(gpa, archetype) catch |err| {
            @constCast(&archetype).deinit(gpa);
            return err;
        };

        if (!entry.found_existing) {
            try self.initTable(gpa, archetype, entry.value_ptr);
        } else {
            @constCast(&archetype).deinit(gpa);
        }

        return @enumFromInt(entry.index);
    }

    /// Asserts that the entity exists.
    fn getEntityLocation(self: Tables, entity_id: EntityId) *EntityLocation {
        const entry = &self.entities.items[entity_id.idx];
        assert(entry.egen == entity_id.gen);
        return &entry.data.eloc;
    }

    /// Asserts that the entity exists.
    fn getEntityTable(self: Tables, entity_id: EntityId) *Table {
        return &self.tables.values()[@intFromEnum(self.getEntityLocation(entity_id).aid)];
    }

    /// Asserts that the entity exists.
    fn getEntityArchetype(self: Tables, entity_id: EntityId) *Archetype {
        return &self.tables.keys()[@intFromEnum(self.getEntityLocation(entity_id).aid)];
    }

    fn moveEntity(
        self: *Tables,
        gpa: Allocator,
        eloc: *EntityLocation,
        dst_aid: ArchetypeIndex,
    ) Oom!void {
        const src = &self.tables.values()[@intFromEnum(eloc.aid)];
        const dst = &self.tables.values()[@intFromEnum(dst_aid)];

        // Copy entity from `src` into `dst`
        try dst.copy(gpa, src, eloc.row);

        src.swapRemove(eloc.row);
        if (src.count != eloc.row) {
            // Set swapped entity
            const eidx = src.entity_ids.items[eloc.row];
            self.getEntityLocation(eidx).row = eloc.row;
        }

        // Update entity storage
        eloc.row = @intCast(dst.count - 1);
        eloc.aid = dst_aid;
    }

    /// Spawns an entity with no components.
    pub fn spawn(self: *Tables, gpa: Allocator) Oom!EntityId {
        const aid = try self.ensureArchetypeExists(gpa, .empty);
        const table = &self.tables.values()[@intFromEnum(aid)];

        const entity_id = try self.prepareNextEntitySlot(gpa, .{
            .aid = aid,
            .row = @intCast(table.count),
        });
        errdefer self.freeEntitySlot(entity_id.idx);

        try table.addOne(gpa, entity_id);

        return entity_id;
    }

    /// Spawns an entity with several components.
    pub fn spawnWith(self: *Tables, gpa: Allocator, components: anytype) Oom!EntityId {
        // TODO: Assert that components is a set.
        //       Currently will fail at runtime with assertion.
        const set_info = @typeInfo(@TypeOf(components));
        if (set_info != .@"struct") {
            @compileError("Expected a struct found: " ++ @typeName(@TypeOf(components)));
        }

        const fields = set_info.@"struct".fields;

        var cids: [fields.len]ComponentId = undefined;
        inline for (fields, &cids) |field, *cid| {
            cid.* = self.getComponentId(field.type).?;
        }

        // Duplicate `cids` to avoid clobbering such that it remains
        //  parallel with `fields`.
        var cids_sorted: [fields.len]ComponentId = cids;

        // Archetype that exists in stack memory.
        const archetype = Archetype.initUnsorted(&cids_sorted);

        // Clones archetype if it doesn't exist.
        const aid = try self.ensureUnownedArchetypeExists(gpa, archetype);
        const table = &self.tables.values()[@intFromEnum(aid)];

        const entity_id = try self.prepareNextEntitySlot(gpa, .{
            .aid = aid,
            .row = @intCast(table.count),
        });
        errdefer self.freeEntitySlot(entity_id.idx);

        try table.addOne(gpa, entity_id);
        inline for (fields, cids) |field, cid| {
            self.erasedSetComponentOnEntity(entity_id, cid, &std.mem.toBytes(@field(components, field.name)));
        }

        return entity_id;
    }

    /// Removes entity assocaited with `entity_id` from `self`.
    /// None of the related archetypes or tables are deinitialized.
    pub fn despawn(self: *Tables, entity_id: EntityId) void {
        const entity_entry = &self.entities.items[entity_id.idx];
        if (entity_entry.egen != entity_id.gen) return;

        const eloc = entity_entry.data.eloc;
        const table = &self.tables.values()[@intFromEnum(eloc.aid)];

        const swapped = table.count - 1;
        table.swapRemove(eloc.row);

        if (swapped != eloc.row) {
            const swapped_entity_id = table.entity_ids.items[swapped];
            const swapped_entity_info = self.getEntityLocation(swapped_entity_id);
            swapped_entity_info.row = eloc.row;
        }

        entity_entry.egen += 1;
        entity_entry.data = .{ .next = self.next_free_entry };
        self.next_free_entry = entity_id.idx;
    }

    /// Checks if the entity associated with `entity_id` is alive.
    pub fn isAlive(self: Tables, entity_id: EntityId) bool {
        const nodes = self.entities.items;
        if (entity_id.idx >= nodes.len) return false;
        if (nodes[entity_id.gen].egen != entity_id.gen) return false;
        return true;
    }

    /// 'Dels' a component on an entity.
    /// Asserts that the entity exists.
    pub fn delComponentOnEntity(
        self: *Tables,
        gpa: Allocator,
        entity_id: EntityId,
        C: type,
    ) Oom!void {
        try self.erasedDelComponentOnEntity(gpa, entity_id, self.getComponentId(C).?);
    }

    /// 'Dels' a component on an entity.
    /// Asserts that the entity exists.
    pub fn erasedDelComponentOnEntity(
        self: *Tables,
        gpa: Allocator,
        entity_id: EntityId,
        component_id: ComponentId,
    ) Oom!void {
        const eloc = self.getEntityLocation(entity_id);

        const archetype = self.tables.keys()[@intFromEnum(eloc.aid)];

        // Entity doesn't have component.
        if (!archetype.contains(component_id)) return;

        const aid = try self.ensureArchetypeExists(gpa, try archetype.remove(gpa, component_id));

        try self.moveEntity(gpa, eloc, aid);
    }

    /// 'Puts' a component onto an entity.
    /// This function only allocates if the entity doesn't store component type.
    /// Asserts that the entity exists.
    pub fn putComponentOnEntity(
        self: *Tables,
        gpa: Allocator,
        entity_id: EntityId,
        Component: type,
        component: Component,
    ) Oom!void {
        const bytes = std.mem.asBytes(&component);

        try self.erasedPutComponentOnEntity(gpa, entity_id, self.getComponentId(Component).?, bytes);
    }

    /// 'Puts' a component onto an entity.
    /// This function only allocates if the entity doesn't store component type.
    /// Asserts that the entity exists.
    pub fn erasedPutComponentOnEntity(
        self: *Tables,
        gpa: Allocator,
        entity_id: EntityId,
        component_id: ComponentId,
        component: []const u8,
    ) Oom!void {
        const archetype = self.getEntityArchetype(entity_id);

        if (!archetype.contains(component_id)) {
            try self.erasedAddComponentToEntity(gpa, entity_id, component_id, component);
        } else {
            self.erasedSetComponentOnEntity(entity_id, component_id, component);
        }
    }

    /// 'Adds' a component to an entity.
    /// Asserts that the entity exists.
    /// Asserts that the entity doesn't store the component type.
    pub fn addComponentToEntity(
        self: *Tables,
        gpa: Allocator,
        entity_id: EntityId,
        Component: type,
        component: Component,
    ) Oom!void {
        const bytes = std.mem.asBytes(&component);

        try self.erasedAddComponentToEntity(gpa, entity_id, self.getComponentId(Component).?, bytes);
    }

    /// 'Adds' a component to an entity.
    /// Asserts that the entity exists.
    /// Asserts that the entity doesn't store the component type.
    /// Asserts that the `component` alignment and size match the
    ///  description given by `component_id`.
    pub fn erasedAddComponentToEntity(
        self: *Tables,
        gpa: Allocator,
        entity_id: EntityId,
        component_id: ComponentId,
        component: []const u8,
    ) Oom!void {
        const eloc = self.getEntityLocation(entity_id);
        const archetype = self.getEntityArchetype(entity_id);

        // Asserts that the component_id does not exist in
        // `archetype`.
        const new_aid = try self.ensureArchetypeExists(gpa, try archetype.add(gpa, component_id));

        try self.moveEntity(gpa, eloc, new_aid);

        self.erasedSetComponentOnEntity(entity_id, component_id, component);
    }

    /// 'Sets' a component onto an entity.
    /// Asserts that `Component` is registered.
    /// Asserts that the entity exists.
    /// Asserts that the entity already stores the component type.
    pub fn setComponentOnEntity(
        self: *Tables,
        entity_id: EntityId,
        Component: type,
        component: Component,
    ) void {
        const bytes = std.mem.asBytes(&component);

        self.erasedSetComponentOnEntity(entity_id, self.getComponentId(Component).?, bytes);
    }

    /// 'Sets' a component onto an entity.
    /// Asserts that the entity exists.
    /// Asserts that the entity already stores the component type.
    /// Asserts that `component` alignment and size match `component_id`.
    pub fn erasedSetComponentOnEntity(
        self: *Tables,
        entity_id: EntityId,
        component_id: ComponentId,
        component: []const u8,
    ) void {
        const eloc = self.getEntityLocation(entity_id);
        const table = self.getEntityTable(entity_id);

        // Asserts that the table exists.
        const column = table.getColumnPtr(component_id).?;
        @memcpy(column.getItemSlot(eloc.row), component);
    }

    /// 'Gets' a component from an entity.
    /// Asserts that `Component` is registered.
    /// Asserts that the entity exists.
    pub fn getComponentOnEntity(
        self: Tables,
        entity_id: EntityId,
        Component: type,
    ) ?*Component {
        const ptr = self.erasedGetComponentOnEntity(entity_id, self.getComponentId(Component).?) orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    /// 'Gets' a component from an entity.
    /// Asserts that the entity exists.
    pub fn erasedGetComponentOnEntity(
        self: Tables,
        entity_id: EntityId,
        component_id: ComponentId,
    ) ?*anyopaque {
        const loc = self.getEntityLocation(entity_id);

        const table = self.tables.values()[@intFromEnum(loc.aid)];
        const column = table.getColumn(component_id) orelse return null;
        return column.getItemPtr(loc.row);
    }

    pub fn Slice(Components: type) type {
        const fields = std.meta.fields(Components);
        const Field = std.meta.FieldEnum(Components);

        return struct {
            len: usize,
            ptrs: [fields.len]*u8,

            pub const Self = @This();

            pub const empty: Slice = .{
                .ptrs = undefined,
                .len = 0,
            };

            fn FieldType(comptime field: Field) type {
                return @FieldType(Components, @tagName(field));
            }

            pub fn items(self: Self, comptime field: Field) []FieldType(field) {
                const F = FieldType(field);
                const byte_ptr = self.ptrs[@intFromEnum(field)];
                const casted_ptr: [*]F = if (@sizeOf(F) == 0) undefined else @ptrCast(@alignCast(byte_ptr));
                return casted_ptr[0..self.len];
            }
        };
    }

    pub fn Iterator(Components: type) type {
        const fields = std.meta.fields(Components);

        return struct {
            component_ids: [fields.len]ComponentId,
            tables: []Table,
            i: usize = 0,

            pub const It = @This();

            pub fn next(it: *It) ?Slice(Components) {
                if (it.i == it.tables.len) return null;

                loop: while (it.i < it.tables.len) {
                    defer it.i += 1;

                    var slice: Slice(Components) = undefined;
                    const table = it.tables[it.i];

                    slice.len = table.count;

                    inline for (0..fields.len) |j| {
                        const cid = it.component_ids[j];
                        const col = table.getColumn(cid) orelse continue :loop;

                        slice.ptrs[j] = @ptrCast(col.data);
                    }

                    return slice;
                }

                return null;
            }
        };
    }

    pub fn iterator(self: Tables, Components: type) Iterator(Components) {
        const fields = std.meta.fields(Components);

        var ids: [fields.len]ComponentId = undefined;
        inline for (&ids, fields) |*id, f| {
            id.* = self.getComponentId(f.type).?;
        }

        return .{
            .component_ids = ids,
            .tables = self.tables.values(),
            .i = 0,
        };
    }
};

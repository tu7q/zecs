pub fn main() anyerror!void {
    // Standard allocator stuff.
    var da_impl = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(da_impl.deinit() == .ok);
    const gpa = da_impl.allocator();

    // Create the tables for the ecs.
    // Whenever an argument requires an allocator we must use the same allocator.
    var tables: zecs.Tables = .empty;
    defer tables.deinit(gpa);

    // Some components that we want to store in the ecs
    const Velocity = struct { dx: f32, dy: f32 };
    const Position = struct { x: f32, y: f32 };

    // We need to make sure they're registered otherwise
    // we'll encounter a runtime assertion.
    _ = try tables.registerComponent(gpa, Velocity);
    _ = try tables.registerComponent(gpa, Position);

    // We can use some nice syntax to spawn an entity with multiple
    // components at once.
    // Otherwise we would have todo:
    //  const entity_id = try tables.spawn(gpa);
    //  try tables.addComponentToEntity(gpa, entity_id, Position, .{...});
    //  try tables.addComponentToEntity(gpa, entity_id, Velocity, .{...});
    // Note that there are other such tables.[put|set|add|get|del]Component[On|To]Entity methods
    // with various differences and use cases.
    const entity_id = try tables.spawnWith(gpa, .{
        Position{ .x = 0, .y = 0 },
        Velocity{ .dx = 1, .dy = 1 },
    });

    for (0..100) |_| {
        // Construct an iterator over the position and velocity components of an entity
        // Note that this is not restrictive. So an entity with more than just these components
        // Will also appear in this iterator. Modifying the table by adding or removing components
        // Will invalidate the iterator.
        var it = tables.iterator(struct {
            pos: Position,
            vel: Velocity,
        });
        while (it.next()) |slice| {
            // The slice here is similar to a MultiArrayList.Slice.

            for (slice.items(.pos), slice.items(.vel)) |*pos, vel| {
                pos.x += vel.dx;
                pos.y += vel.dy;
            }
        }
    }

    const velocity = tables.getComponentOnEntity(entity_id, Velocity).?;
    const position = tables.getComponentOnEntity(entity_id, Position).?;

    std.debug.print("{any} {any}\n", .{ velocity, position });

    // Not required since we already call .deinit(gpa) on `tables`.
    tables.despawn(entity_id);

    // And we can see that the entity id is no longer useable.
    std.debug.print("{any}\n", .{tables.isAlive(entity_id)});
}

const std = @import("std");
const zecs = @import("zecs");

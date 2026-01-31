# zecs

## An Entity Component System

This projects uses zig 0.15.2

### Status
**Immature**

## Building and using

Download and add ecs.zig as a dependency by running the following command in your project root:
```
zig fetch --save git+https://github.com/tu7q/zecs/
```

Then add zecs as a dependency and import its modules in your `build.zig`:

```zig
const zecs = b.dependency("zecs", .{
	.target=target,
	.optimize=optimize,
});
exe.root_module.addImport("zecs", zecs.module("zecs"));
```

Then import it with `const zecs = @import("zecs");` and build as normal with `zig build`.

<!-- TODOS -->
## TODOS
 - Using something like a german string for the Archetypes to store some ComponentId on the stack.
 - Using a graph structure to follow edges between archetypes.
 - API to allow inserting/getting multiple elements at once
 - Cleaner column usage/reducing required column information.
 - Better Query/Iteration API
 - Use something like https://osebje.famnit.upr.si/~savnik/papers/cdares13.pdf for faster iteration.


<!-- DOCUMENTATION -->
## Documentation
Use the following to build the API reference.
```sh
zig build docs
```
They can then be served locally using python:
```sh
python -m http.server 8000 -d zig-out/docs/
```

<!-- LICENSE -->
## License
Distributed under the MIT License. See `LICENSE` for more information.

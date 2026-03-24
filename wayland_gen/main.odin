package wayland_gen

import "core:fmt"
import "core:mem"
import "core:os"

main :: proc() {
	if len(os.args) != 3 {
		fmt.eprintln("Usage: wayland_gen <input.xml> <output_dir>")
		os.exit(1)
	}

	input_path := os.args[1]
	output_path := os.args[2]

	data, err := os.read_entire_file_from_path(input_path, context.allocator)
	if err != os.ERROR_NONE {
		fmt.eprintf("Error: could not read input file '%s': %v\n", input_path, err)
		os.exit(1)
	}
	defer delete(data)

	// All protocol IR allocations go into an arena; freeing the arena releases everything.
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	protocol: Protocol
	parse_ok: bool
	{
		context.allocator = mem.dynamic_arena_allocator(&arena)
		protocol, parse_ok = parse_protocol(data)
	}
	if !parse_ok {
		os.exit(1)
	}

	if !validate_protocol(&protocol) {
		os.exit(1)
	}

	if !generate(output_path, &protocol) {
		os.exit(1)
	}
}

package wayland_gen

import "core:fmt"
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

	protocol, parse_ok := parse_protocol(data)
	if !parse_ok {
		os.exit(1)
	}
	defer protocol_destroy(&protocol)

	if !validate_protocol(&protocol) {
		os.exit(1)
	}

	if !generate(output_path, &protocol) {
		os.exit(1)
	}
}

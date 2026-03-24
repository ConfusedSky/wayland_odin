package wayland_gen

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

FILE_HEADER :: "// This file was auto-generated\n// DO NOT EDIT\n"

generate :: proc(output_dir: string, p: ^Protocol) -> bool {
	if !os.is_dir(output_dir) {
		if err := os.make_directory(output_dir); err != os.ERROR_NONE {
			fmt.eprintf("Error: could not create output directory '%s': %v\n", output_dir, err)
			return false
		}
	}

	for &iface in p.interfaces {
		if !generate_interface(output_dir, &iface) do return false
	}

	return true
}

// Scans all request args to determine what imports the file needs.
// cross_pkgs entries are slices into existing enum_ref strings (not owned).
// Caller owns the returned dynamic array itself.
collect_imports :: proc(iface: ^Interface) -> (needs_linux: bool, cross_pkgs: [dynamic]string) {
	seen: map[string]bool
	defer delete(seen)

	needs_linux = len(iface.requests) > 0

	for &req in iface.requests {
		for &arg in req.args {
			if arg.enum_ref != "" {
				dot := strings.last_index(arg.enum_ref, ".")
				if dot != -1 {
					pkg := arg.enum_ref[:dot]
					if !seen[pkg] {
						seen[pkg] = true
						append(&cross_pkgs, pkg)
					}
				}
			}
		}
	}
	return
}

generate_interface :: proc(output_dir: string, iface: ^Interface) -> bool {
	iface_dir, _ := filepath.join({output_dir, iface.name}, context.allocator)
	defer delete(iface_dir)

	if !os.is_dir(iface_dir) {
		if err := os.make_directory(iface_dir); err != os.ERROR_NONE {
			fmt.eprintf("Error: could not create directory '%s': %v\n", iface_dir, err)
			return false
		}
	}

	sb: strings.Builder
	strings.builder_init(&sb)
	defer strings.builder_destroy(&sb)

	// File header
	strings.write_string(&sb, FILE_HEADER)
	strings.write_byte(&sb, '\n')

	// Package declaration
	fmt.sbprintf(&sb, "package %s\n", iface.name)

	// Imports
	needs_linux, cross_pkgs := collect_imports(iface)
	defer delete(cross_pkgs)
	if needs_linux || len(cross_pkgs) > 0 {
		strings.write_byte(&sb, '\n')
		if needs_linux {
			strings.write_string(&sb, "import \"core:sys/linux\"\n")
		}
		for pkg in cross_pkgs {
			fmt.sbprintf(&sb, "import %s \"../%s\"\n", pkg, pkg)
		}
	}

	// Request constants
	if len(iface.requests) > 0 {
		strings.write_byte(&sb, '\n')
		for &req in iface.requests {
			emit_request(&sb, &req)
		}
	}

	// Request procedures
	if len(iface.requests) > 0 {
		for &req in iface.requests {
			emit_request_proc(&sb, &req, iface.name)
		}
	}

	// Events
	if len(iface.events) > 0 {
		strings.write_byte(&sb, '\n')
		for &ev in iface.events {
			emit_event(&sb, &ev)
		}
	}

	// Enums
	if len(iface.enums) > 0 {
		strings.write_byte(&sb, '\n')
		for &en in iface.enums {
			emit_enum(&sb, &en, iface.name)
		}
	}

	filename := strings.concatenate({iface.name, ".odin"})
	defer delete(filename)
	out_path, _ := filepath.join({iface_dir, filename}, context.allocator)
	defer delete(out_path)

	content := strings.to_string(sb)
	if err := os.write_entire_file(out_path, transmute([]byte)content); err != os.ERROR_NONE {
		fmt.eprintf("Error: could not write file '%s': %v\n", out_path, err)
		return false
	}

	return true
}

emit_request :: proc(sb: ^strings.Builder, req: ^Request) {
	upper := to_upper_snake(req.name)
	defer delete(upper)

	fmt.sbprintf(sb, "%s_REQUEST_OPCODE :: %d\n", upper, req.opcode)
	fmt.sbprintf(sb, "%s_REQUEST_ARG_COUNT :: %d\n", upper, len(req.args))

	strings.write_byte(sb, '\n')
}

emit_request_proc :: proc(sb: ^strings.Builder, req: ^Request, iface_name: string) {
	doc := format_request_doc_comment(req.description, req.args)
	defer delete(doc)
	strings.write_string(sb, doc)

	fmt.sbprintf(sb, "%s :: proc(socket: linux.Fd, %s: u32", req.name, iface_name)

	for &arg in req.args {
		param_name: string
		if arg.type == "new_id" {
			param_name = arg.name == "id" ? strings.clone("new_id") : strings.concatenate({arg.name, "_new_id"})
		} else {
			param_name = strings.clone(arg.name)
		}
		defer delete(param_name)

		type_str := arg_type_to_odin_type(arg)
		defer delete(type_str)

		fmt.sbprintf(sb, ", %s: %s", param_name, type_str)
	}

	strings.write_string(sb, ") {\n\tunimplemented()\n}\n\n")
}

emit_event :: proc(sb: ^strings.Builder, ev: ^Event) {
	upper := to_upper_snake(ev.name)
	defer delete(upper)

	desc_comment := format_description_comment(ev.description)
	defer delete(desc_comment)
	fmt.sbprintf(sb, "%s\n", desc_comment)
	fmt.sbprintf(sb, "%s_EVENT_OPCODE :: %d\n", upper, ev.opcode)

	if len(ev.args) > 0 {
		arg_comments := format_arg_comments(ev.args)
		defer delete(arg_comments)
		fmt.sbprintf(sb, "%s\n", arg_comments)
	}
	fmt.sbprintf(sb, "%s_EVENT_ARG_COUNT :: %d\n", upper, len(ev.args))

	strings.write_byte(sb, '\n')
}

emit_enum :: proc(sb: ^strings.Builder, en: ^Enum, iface_name: string) {
	camel := to_camel_case(en.name)
	defer delete(camel)

	if en.bitfield {
		emit_bitfield_enum(sb, en, camel, iface_name)
	} else {
		emit_plain_enum(sb, en, camel)
	}

	strings.write_byte(sb, '\n')
}

emit_plain_enum :: proc(sb: ^strings.Builder, en: ^Enum, camel: string) {
	fmt.sbprintf(sb, "%s :: enum u32 {{\n", camel)
	for &entry in en.entries {
		entry_camel := to_camel_case(entry.name)
		defer delete(entry_camel)
		if entry.summary != "" {
			fmt.sbprintf(sb, "\t// %s\n", entry.summary)
		}
		fmt.sbprintf(sb, "\t%s = %s,\n", entry_camel, entry.value)
	}
	strings.write_string(sb, "}\n")
}

emit_bitfield_enum :: proc(sb: ^strings.Builder, en: ^Enum, camel: string, iface_name: string) {
	flag_name := strings.concatenate({camel, "Flag"})
	defer delete(flag_name)

	fmt.sbprintf(sb, "%s :: enum u32 {{\n", flag_name)

	for &entry in en.entries {
		val, ok := strconv.parse_u64(entry.value)
		if !ok {
			fmt.eprintf(
				"warn: %s.%s.%s (value=%q): could not parse value, skipping\n",
				iface_name,
				en.name,
				entry.name,
				entry.value,
			)
			continue
		}
		if val == 0 {
			fmt.eprintf(
				"warn: %s.%s.%s (value=0): zero entry has no bit index, skipping\n",
				iface_name,
				en.name,
				entry.name,
			)
			continue
		}
		if val & (val - 1) != 0 {
			fmt.eprintf(
				"warn: %s.%s.%s (value=%s): composite value is not a power of 2, skipping\n",
				iface_name,
				en.name,
				entry.name,
				entry.value,
			)
			continue
		}

		bit_index: u64 = 0
		v := val
		for v > 1 {
			v >>= 1
			bit_index += 1
		}

		entry_camel := to_camel_case(entry.name)
		defer delete(entry_camel)
		if entry.summary != "" {
			fmt.sbprintf(sb, "\t// %s\n", entry.summary)
		}
		fmt.sbprintf(sb, "\t%s = %d,\n", entry_camel, bit_index)
	}

	strings.write_string(sb, "}\n")
	fmt.sbprintf(sb, "%s :: bit_set[%s; u32]\n", camel, flag_name)
}

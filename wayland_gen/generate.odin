package wayland_gen

import "core:fmt"
import "core:os"
import "core:path/filepath"
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

	// Requests
	if len(iface.requests) > 0 {
		strings.write_byte(&sb, '\n')
		for &req in iface.requests {
			emit_request(&sb, &req)
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
			emit_enum(&sb, &en)
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

	desc_comment := format_description_comment(req.description)
	defer delete(desc_comment)
	fmt.sbprintf(sb, "%s\n", desc_comment)
	fmt.sbprintf(sb, "%s_REQUEST_OPCODE :: %d\n", upper, req.opcode)

	if len(req.args) > 0 {
		arg_comments := format_arg_comments(req.args)
		defer delete(arg_comments)
		fmt.sbprintf(sb, "%s\n", arg_comments)
	}
	fmt.sbprintf(sb, "%s_REQUEST_ARG_COUNT :: %d\n", upper, len(req.args))

	strings.write_byte(sb, '\n')
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

emit_enum :: proc(sb: ^strings.Builder, en: ^Enum) {
	camel := to_camel_case(en.name)
	defer delete(camel)

	if en.bitfield {
		emit_bitfield_enum(sb, en, camel)
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

emit_bitfield_enum :: proc(sb: ^strings.Builder, en: ^Enum, camel: string) {
	flag_name := strings.concatenate({camel, "Flag"})
	defer delete(flag_name)

	// Use existing zero entry name if present, otherwise synthesise "None"
	zero_label := "None"
	zero_label_alloc := false
	for &entry in en.entries {
		if entry.value == "0" {
			zero_label = to_camel_case(entry.name)
			zero_label_alloc = true
			break
		}
	}
	defer if zero_label_alloc do delete(zero_label)

	fmt.sbprintf(sb, "%s :: enum u32 {{\n", flag_name)
	fmt.sbprintf(sb, "\t%s = 0,\n", zero_label)

	for &entry in en.entries {
		if entry.value == "0" do continue
		entry_camel := to_camel_case(entry.name)
		defer delete(entry_camel)
		if entry.summary != "" {
			fmt.sbprintf(sb, "\t// %s\n", entry.summary)
		}
		fmt.sbprintf(sb, "\t%s = %s,\n", entry_camel, entry.value)
	}
	strings.write_string(sb, "}\n")

	fmt.sbprintf(sb, "%s :: bit_set[%s; u32]\n", camel, flag_name)
}

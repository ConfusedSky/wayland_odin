package wayland_gen

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

FILE_HEADER :: "// This file was auto-generated\n// DO NOT EDIT\n"

// Derive the enums-package name from the protocol name.
// e.g. "wayland" -> "wayland_enums", "xdg-shell" -> "xdg_shell_enums"
protocol_enums_pkg :: proc(protocol_name: string) -> string {
	sb: strings.Builder
	strings.builder_init(&sb)
	for ch in protocol_name {
		if ch == '-' {
			strings.write_byte(&sb, '_')
		} else {
			strings.write_rune(&sb, ch)
		}
	}
	strings.write_string(&sb, "_enums")
	return strings.to_string(sb)
}

generate :: proc(output_dir: string, p: ^Protocol) -> bool {
	if !os.is_dir(output_dir) {
		if err := os.make_directory(output_dir); err != os.ERROR_NONE {
			fmt.eprintf("Error: could not create output directory '%s': %v\n", output_dir, err)
			return false
		}
	}

	enums_pkg := protocol_enums_pkg(p.name)
	defer delete(enums_pkg)

	if !generate_enums_package(output_dir, p, enums_pkg) do return false

	// Pre-pass: collect all interfaces that appear as typed new_id targets.
	// Any interface NOT in this set (and not wl_display) is a "global" — only
	// reachable via wl_registry.bind — and gets a from_global constructor.
	non_globals: map[string]bool
	defer delete(non_globals)
	for &iface in p.interfaces {
		for &req in iface.requests {
			for &arg in req.args {
				if arg.type == "new_id" && arg.interface != "" {
					non_globals[arg.interface] = true
				}
			}
		}
	}

	for &iface in p.interfaces {
		is_display := iface.name == "wl_display"
		is_global := !is_display && !non_globals[iface.name]
		if !generate_interface(output_dir, &iface, is_display, is_global, enums_pkg) do return false
	}

	return true
}

// Generate a shared enums package containing all enum types from the protocol,
// prefixed with the interface camel name to avoid collisions.
// e.g. wl_shm.format -> WlShmFormat in package wayland_enums
generate_enums_package :: proc(output_dir: string, p: ^Protocol, enums_pkg: string) -> bool {
	has_any := false
	for &iface in p.interfaces {
		if len(iface.enums) > 0 {
			has_any = true
			break
		}
	}
	if !has_any do return true

	enums_dir, _ := filepath.join({output_dir, enums_pkg}, context.allocator)
	defer delete(enums_dir)
	if !os.is_dir(enums_dir) {
		if err := os.make_directory(enums_dir); err != os.ERROR_NONE {
			fmt.eprintf("Error: could not create directory '%s': %v\n", enums_dir, err)
			return false
		}
	}

	sb: strings.Builder
	strings.builder_init(&sb)
	defer strings.builder_destroy(&sb)

	strings.write_string(&sb, FILE_HEADER)
	strings.write_byte(&sb, '\n')
	fmt.sbprintf(&sb, "package %s\n", enums_pkg)

	for &iface in p.interfaces {
		if len(iface.enums) == 0 do continue
		iface_camel := to_camel_case(iface.name)
		defer delete(iface_camel)
		strings.write_byte(&sb, '\n')
		for &en in iface.enums {
			emit_enum_definition(&sb, &en, iface_camel, iface.name)
		}
	}

	filename := strings.concatenate({enums_pkg, ".odin"})
	defer delete(filename)
	out_path, _ := filepath.join({enums_dir, filename}, context.allocator)
	defer delete(out_path)

	content := strings.to_string(sb)
	if err := os.write_entire_file(out_path, transmute([]byte)content); err != os.ERROR_NONE {
		fmt.eprintf("Error: could not write file '%s': %v\n", out_path, err)
		return false
	}

	return true
}

// Emits a fully-prefixed enum definition for the shared enums package.
// e.g. iface_camel="WlShm", en.name="format" → "WlShmFormat :: enum u32 { ... }"
emit_enum_definition :: proc(
	sb: ^strings.Builder,
	en: ^Enum,
	iface_camel: string,
	iface_name: string,
) {
	enum_camel := to_camel_case(en.name)
	defer delete(enum_camel)
	prefixed := strings.concatenate({iface_camel, enum_camel})
	defer delete(prefixed)

	if en.bitfield {
		emit_bitfield_enum(sb, en, prefixed, iface_name)
	} else {
		emit_plain_enum(sb, en, prefixed)
	}
	strings.write_byte(sb, '\n')
}

// Emits type aliases in the interface package that re-export enums from the shared enums package.
// e.g. "Format :: wayland_enums.WlShmFormat"
emit_enum_reexports :: proc(
	sb: ^strings.Builder,
	en: ^Enum,
	iface_name: string,
	enums_pkg: string,
) {
	iface_camel := to_camel_case(iface_name)
	defer delete(iface_camel)
	enum_camel := to_camel_case(en.name)
	defer delete(enum_camel)
	prefixed := strings.concatenate({iface_camel, enum_camel})
	defer delete(prefixed)

	if en.bitfield {
		fmt.sbprintf(sb, "%sFlag :: %s.%sFlag\n", enum_camel, enums_pkg, prefixed)
		fmt.sbprintf(sb, "%s :: %s.%s\n", enum_camel, enums_pkg, prefixed)
	} else {
		fmt.sbprintf(sb, "%s :: %s.%s\n", enum_camel, enums_pkg, prefixed)
	}
	strings.write_byte(sb, '\n')
}

// collect_imports returns flags and the unified set of cross-package imports
// the generated file needs. extra_pkgs is owned by the caller.
collect_imports :: proc(
	iface: ^Interface,
	is_global: bool,
	enums_pkg: string,
) -> (
	has_requests: bool,
	extra_pkgs: [dynamic]string,
) {
	seen: map[string]bool
	defer delete(seen)

	has_requests = len(iface.requests) > 0

	// Need the enums package if this interface defines enums (for re-exports)
	// or if any request/event arg references a cross-package enum.
	needs_enums_pkg := len(iface.enums) > 0

	// Globals need wl_registry for from_global
	if is_global {
		seen["wl_registry"] = true
		append(&extra_pkgs, "wl_registry")
	}

	for &req in iface.requests {
		for &arg in req.args {
			if arg.enum_ref != "" {
				_, _, cross := split_enum_ref(arg.enum_ref)
				if cross do needs_enums_pkg = true
			}
			// Import packages for proxy return types (new_id) and proxy params (object).
			// Cross-package enum refs are resolved through the shared enums package instead.
			// Skip self-imports: the current interface is already in scope as ^t.
			if (arg.type == "new_id" || arg.type == "object") &&
			   arg.interface != "" &&
			   arg.interface != iface.name {
				if !seen[arg.interface] {
					seen[arg.interface] = true
					append(&extra_pkgs, arg.interface)
				}
			}
		}
	}

	for &ev in iface.events {
		for &arg in ev.args {
			if arg.enum_ref != "" {
				_, _, cross := split_enum_ref(arg.enum_ref)
				if cross do needs_enums_pkg = true
			}
		}
	}

	if needs_enums_pkg && enums_pkg != "" && !seen[enums_pkg] {
		seen[enums_pkg] = true
		append(&extra_pkgs, enums_pkg)
	}

	return
}

generate_interface :: proc(
	output_dir: string,
	iface: ^Interface,
	is_display: bool,
	is_global: bool,
	enums_pkg: string,
) -> bool {
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

	strings.write_string(&sb, FILE_HEADER)
	strings.write_byte(&sb, '\n')
	fmt.sbprintf(&sb, "package %s\n", iface.name)

	has_requests, extra_pkgs := collect_imports(iface, is_global, enums_pkg)
	defer delete(extra_pkgs)
	has_events := len(iface.events) > 0

	// linux is always needed for the proxy t struct (linux.Fd field).
	// fmt is needed wherever we emit logging.
	needs_fmt := has_requests || has_events || is_global
	needs_bw := has_requests || is_global

	strings.write_byte(&sb, '\n')
	if needs_fmt do strings.write_string(&sb, "import \"core:fmt\"\n")
	strings.write_string(&sb, "import \"core:sys/linux\"\n")
	if needs_bw {
		strings.write_string(&sb, "import buf_writer \"../../buf_writer\"\n")
		strings.write_string(&sb, "import constants \"../../constants\"\n")
	}
	if has_events {
		strings.write_string(&sb, "import buf_reader \"../../buf_reader\"\n")
	}
	for pkg in extra_pkgs {
		fmt.sbprintf(&sb, "import %s \"../%s\"\n", pkg, pkg)
	}

	// Proxy type
	emit_proxy_type(&sb, is_display, iface.description)

	// Constructor: init for wl_display, from_global for registry-bound globals
	if is_display {
		emit_init_proc(&sb)
	} else if is_global {
		emit_from_global(&sb, iface.name)
	}

	// Request opcodes and procs
	if len(iface.requests) > 0 {
		strings.write_byte(&sb, '\n')
		for &req in iface.requests {
			emit_request(&sb, &req)
		}
		for &req in iface.requests {
			emit_request_proc(&sb, &req, iface.name, is_display, enums_pkg)
		}
	}

	// Events
	if len(iface.events) > 0 {
		strings.write_byte(&sb, '\n')
		for &ev in iface.events {
			emit_event(&sb, &ev, enums_pkg)
		}
		emit_event_handlers_struct(&sb, iface)
		strings.write_byte(&sb, '\n')
		emit_handle_event_proc(&sb, iface, enums_pkg)
	}

	// Enum re-exports (aliases into the shared enums package)
	if len(iface.enums) > 0 && enums_pkg != "" {
		strings.write_byte(&sb, '\n')
		for &en in iface.enums {
			emit_enum_reexports(&sb, &en, iface.name, enums_pkg)
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

emit_proxy_type :: proc(sb: ^strings.Builder, is_display: bool, desc: Maybe(Description)) {
	strings.write_byte(sb, '\n')
	desc_comment := format_description_comment(desc)
	defer delete(desc_comment)
	fmt.sbprintf(sb, "%s\n", desc_comment)
	if is_display {
		strings.write_string(sb, "t :: struct {\n")
		strings.write_string(sb, "\tsocket:  linux.Fd,\n")
		strings.write_string(sb, "\tnext_id: u32,\n")
		strings.write_string(sb, "}\n\n")
	} else {
		strings.write_string(sb, "t :: struct {\n")
		strings.write_string(sb, "\tsocket:  linux.Fd,\n")
		strings.write_string(sb, "\tnext_id: ^u32,\n")
		strings.write_string(sb, "\tid:      u32,\n")
		strings.write_string(sb, "}\n\n")
	}
}

emit_init_proc :: proc(sb: ^strings.Builder) {
	strings.write_string(sb, "init :: proc(socket: linux.Fd) -> t {\n")
	strings.write_string(sb, "\treturn {socket = socket, next_id = 1}\n")
	strings.write_string(sb, "}\n\n")
}

emit_from_global :: proc(sb: ^strings.Builder, iface_name: string) {
	strings.write_string(
		sb,
		"from_global :: proc(registry: ^wl_registry.t, name: u32, version: u32) -> (t, linux.Errno) {\n",
	)
	strings.write_string(sb, "\tregistry.next_id^ += 1\n")
	strings.write_string(sb, "\tid := registry.next_id^\n")
	strings.write_string(sb, "\twriter: buf_writer.Writer(constants.BUF_WRITER_SIZE_STRING)\n")
	strings.write_string(
		sb,
		"\tbuf_writer.initialize(&writer, registry.id, wl_registry.BIND_REQUEST_OPCODE)\n",
	)
	strings.write_string(sb, "\tbuf_writer.write_u32(&writer, name)\n")
	fmt.sbprintf(sb, "\tbuf_writer.write_string(&writer, \"%s\\x00\")\n", iface_name)
	strings.write_string(sb, "\tbuf_writer.write_u32(&writer, version)\n")
	strings.write_string(sb, "\tbuf_writer.write_u32(&writer, id)\n")
	fmt.sbprintf(
		sb,
		"\tfmt.printfln(\"-> wl_registry@%%v.bind: name=%%v interface=%s version=%%v id=%%v\", registry.id, name, version, id)\n",
		iface_name,
	)
	strings.write_string(sb, "\terr := buf_writer.send(&writer, registry.socket)\n")
	strings.write_string(sb, "\tif err != nil do return {}, err\n")
	strings.write_string(
		sb,
		"\treturn t{socket = registry.socket, next_id = registry.next_id, id = id}, nil\n",
	)
	strings.write_string(sb, "}\n\n")
}

emit_request :: proc(sb: ^strings.Builder, req: ^Request) {
	upper := to_upper_snake(req.name)
	defer delete(upper)

	fmt.sbprintf(sb, "%s_REQUEST_OPCODE :: %d\n", upper, req.opcode)
	fmt.sbprintf(sb, "%s_REQUEST_ARG_COUNT :: %d\n", upper, len(req.args))

	strings.write_byte(sb, '\n')
}

emit_request_proc :: proc(
	sb: ^strings.Builder,
	req: ^Request,
	iface_name: string,
	is_display: bool,
	enums_pkg: string,
) {
	// Find the typed new_id arg (if any) — determines whether we return a proxy
	new_id_iface := ""
	for &arg in req.args {
		if arg.type == "new_id" && arg.interface != "" {
			new_id_iface = arg.interface
			break
		}
	}
	has_new_id := new_id_iface != ""

	doc := format_request_doc_comment(req.description, req.args)
	defer delete(doc)
	strings.write_string(sb, doc)

	// --- Signature ---
	fmt.sbprintf(sb, "%s :: proc(%s: ^t", req.name, iface_name)

	write_calls_sb: strings.Builder
	strings.builder_init(&write_calls_sb)
	defer strings.builder_destroy(&write_calls_sb)

	print_fmt_sb: strings.Builder
	strings.builder_init(&print_fmt_sb)
	defer strings.builder_destroy(&print_fmt_sb)

	print_args_sb: strings.Builder
	strings.builder_init(&print_args_sb)
	defer strings.builder_destroy(&print_args_sb)

	asserts_sb: strings.Builder
	strings.builder_init(&asserts_sb)
	defer strings.builder_destroy(&asserts_sb)

	fd_param := ""
	first_print_arg := true
	needs_string_size := false

	upper := to_upper_snake(req.name)
	defer delete(upper)

	for &arg in req.args {
		if arg.type == "string" || arg.type == "array" {
			needs_string_size = true
		}

		// Typed new_id: not a param — id is allocated internally and written to wire
		if arg.type == "new_id" && arg.interface != "" {
			fmt.sbprintf(&write_calls_sb, "\tbuf_writer.write_u32(&writer, new_id)\n")
			if first_print_arg {
				fmt.sbprintf(&print_fmt_sb, "%s=%%v", arg.name)
				first_print_arg = false
			} else {
				fmt.sbprintf(&print_fmt_sb, " %s=%%v", arg.name)
			}
			strings.write_string(&print_args_sb, ", new_id")
			continue
		}

		// fd: not written to wire, used for send_with_fd
		if arg.type == "fd" {
			fmt.sbprintf(sb, ", %s: linux.Fd", arg.name)
			fd_param = arg.name
			continue
		}

		// Object with known interface: typed proxy pointer
		if arg.type == "object" && arg.interface != "" {
			if arg.interface == iface_name {
				fmt.sbprintf(sb, ", %s: ^t", arg.name)
			} else {
				fmt.sbprintf(sb, ", %s: ^%s.t", arg.name, arg.interface)
			}
			fmt.sbprintf(&asserts_sb, "\tassert(%s.id > 0)\n", arg.name)
			fmt.sbprintf(&write_calls_sb, "\tbuf_writer.write_u32(&writer, %s.id)\n", arg.name)
			if first_print_arg {
				fmt.sbprintf(&print_fmt_sb, "%s=%%v", arg.name)
				first_print_arg = false
			} else {
				fmt.sbprintf(&print_fmt_sb, " %s=%%v", arg.name)
			}
			fmt.sbprintf(&print_args_sb, ", %s.id", arg.name)
			continue
		}

		// All other args (primitives, enums, untyped new_id/object)
		param_name: string
		param_owned := false
		if arg.type == "new_id" {
			if arg.name == "id" {
				param_name = "new_id"
			} else {
				param_name = strings.concatenate({arg.name, "_new_id"})
				param_owned = true
			}
		} else {
			param_name = arg.name
		}

		type_str := arg_type_to_odin_type(arg, enums_pkg)
		fmt.sbprintf(sb, ", %s: %s", param_name, type_str)
		delete(type_str)

		if arg.type == "object" {
			fmt.sbprintf(&asserts_sb, "\tassert(%s > 0)\n", param_name)
		}

		switch {
		case arg.enum_ref != "":
			fmt.sbprintf(
				&write_calls_sb,
				"\tbuf_writer.write_u32(&writer, transmute(u32)%s)\n",
				param_name,
			)
		case arg.type == "uint", arg.type == "object", arg.type == "new_id":
			fmt.sbprintf(&write_calls_sb, "\tbuf_writer.write_u32(&writer, %s)\n", param_name)
		case arg.type == "int":
			fmt.sbprintf(&write_calls_sb, "\tbuf_writer.write_i32(&writer, %s)\n", param_name)
		case arg.type == "fixed":
			fmt.sbprintf(
				&write_calls_sb,
				"\tbuf_writer.write_i32(&writer, i32(%s * 256))\n",
				param_name,
			)
		case arg.type == "string":
			fmt.sbprintf(&write_calls_sb, "\tbuf_writer.write_string(&writer, %s)\n", param_name)
		case arg.type == "array":
			fmt.sbprintf(&write_calls_sb, "\tbuf_writer.write_array(&writer, %s)\n", param_name)
		}

		if first_print_arg {
			fmt.sbprintf(&print_fmt_sb, "%s=%%v", arg.name)
			first_print_arg = false
		} else {
			fmt.sbprintf(&print_fmt_sb, " %s=%%v", arg.name)
		}
		fmt.sbprintf(&print_args_sb, ", %s", param_name)

		if param_owned do delete(param_name)
	}

	size_const :=
		needs_string_size ? "constants.BUF_WRITER_SIZE_STRING" : "constants.BUF_WRITER_SIZE_BASE"

	// Return type
	if has_new_id {
		fmt.sbprintf(sb, ") -> (%s.t, linux.Errno) {{\n", new_id_iface)
	} else {
		strings.write_string(sb, ") -> linux.Errno {\n")
	}

	// Proxy assert (display has no id field)
	if !is_display {
		fmt.sbprintf(sb, "\tassert(%s.id > 0)\n", iface_name)
	}
	strings.write_string(sb, strings.to_string(asserts_sb))

	// Allocate next id for typed new_id args
	if has_new_id {
		if is_display {
			fmt.sbprintf(sb, "\t%s.next_id += 1\n", iface_name)
			fmt.sbprintf(sb, "\tnew_id := %s.next_id\n", iface_name)
		} else {
			fmt.sbprintf(sb, "\t%s.next_id^ += 1\n", iface_name)
			fmt.sbprintf(sb, "\tnew_id := %s.next_id^\n", iface_name)
		}
	}

	// Wire write
	obj_id_expr := "1" if is_display else strings.concatenate({iface_name, ".id"})
	defer if !is_display do delete(obj_id_expr)
	fmt.sbprintf(sb, "\twriter: buf_writer.Writer(%s)\n", size_const)
	fmt.sbprintf(
		sb,
		"\tbuf_writer.initialize(&writer, %s, %s_REQUEST_OPCODE)\n",
		obj_id_expr,
		upper,
	)
	strings.write_string(sb, strings.to_string(write_calls_sb))

	// Log
	fmt.sbprintf(
		sb,
		"\tfmt.printfln(\"-> %s@%%v.%s: %s\", %s%s)\n",
		iface_name,
		req.name,
		strings.to_string(print_fmt_sb),
		obj_id_expr,
		strings.to_string(print_args_sb),
	)

	// Send and return
	if has_new_id {
		if fd_param != "" {
			fmt.sbprintf(
				sb,
				"\terr := buf_writer.send_with_fd(&writer, %s.socket, %s)\n",
				iface_name,
				fd_param,
			)
		} else {
			fmt.sbprintf(sb, "\terr := buf_writer.send(&writer, %s.socket)\n", iface_name)
		}
		if is_display {
			fmt.sbprintf(
				sb,
				"\treturn %s.t{{socket = %s.socket, next_id = &%s.next_id, id = new_id}}, err\n",
				new_id_iface,
				iface_name,
				iface_name,
			)
		} else {
			fmt.sbprintf(
				sb,
				"\treturn %s.t{{socket = %s.socket, next_id = %s.next_id, id = new_id}}, err\n",
				new_id_iface,
				iface_name,
				iface_name,
			)
		}
	} else {
		if fd_param != "" {
			fmt.sbprintf(
				sb,
				"\treturn buf_writer.send_with_fd(&writer, %s.socket, %s)\n",
				iface_name,
				fd_param,
			)
		} else {
			fmt.sbprintf(sb, "\treturn buf_writer.send(&writer, %s.socket)\n", iface_name)
		}
	}

	strings.write_string(sb, "}\n\n")
}

emit_event :: proc(sb: ^strings.Builder, ev: ^Event, enums_pkg: string) {
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
	emit_event_handler(sb, ev, enums_pkg)

	strings.write_byte(sb, '\n')
}

emit_event_handler :: proc(sb: ^strings.Builder, ev: ^Event, enums_pkg: string) {
	handler_name := strings.concatenate({"On", to_camel_case(ev.name)})
	defer delete(handler_name)

	fmt.sbprintf(sb, "%s :: proc(source_object_id: u32, ", handler_name)
	for arg, i in ev.args {
		if i > 0 do strings.write_string(sb, ", ")
		type_str := arg_type_to_odin_type(arg, enums_pkg)
		defer delete(type_str)
		fmt.sbprintf(sb, "%s: %s", arg.name, type_str)
	}
	if len(ev.args) > 0 do strings.write_string(sb, ", ")
	strings.write_string(sb, "user_data: rawptr) -> linux.Errno\n")
}

emit_event_handlers_struct :: proc(sb: ^strings.Builder, iface: ^Interface) {
	strings.write_string(sb, "EventHandlers :: struct {\n")
	for &ev in iface.events {
		handler_name := strings.concatenate({"On", to_camel_case(ev.name)})
		defer delete(handler_name)
		fmt.sbprintf(sb, "\ton_%s: %s,\n", ev.name, handler_name)
	}
	strings.write_string(sb, "}\n")
}

emit_handle_event_proc :: proc(sb: ^strings.Builder, iface: ^Interface, enums_pkg: string) {
	fmt.sbprintf(
		sb,
		"handle_event :: proc(object_id: u32, opcode: u16, msg: ^^u8, msg_len: ^int, handlers_raw: rawptr, user_data: rawptr, fds: ^[]linux.Fd) -> linux.Errno {{\n",
	)
	fmt.sbprintf(sb, "\thandlers := (^EventHandlers)(handlers_raw)\n")
	strings.write_string(sb, "\tswitch opcode {\n")

	for &ev in iface.events {
		upper := to_upper_snake(ev.name)
		defer delete(upper)

		fmt.sbprintf(sb, "\tcase %s_EVENT_OPCODE:\n", upper)

		print_fmt_sb: strings.Builder
		strings.builder_init(&print_fmt_sb)
		defer strings.builder_destroy(&print_fmt_sb)

		print_args_sb: strings.Builder
		strings.builder_init(&print_args_sb)
		defer strings.builder_destroy(&print_args_sb)

		call_args_sb: strings.Builder
		strings.builder_init(&call_args_sb)
		defer strings.builder_destroy(&call_args_sb)

		first_print_arg := true

		for &arg in ev.args {
			if arg.type == "fd" {
				fmt.sbprintf(sb, "\t\t%s := fds[0]; fds^ = fds[1:]\n", arg.name)
			} else {
				switch {
				case arg.enum_ref != "":
					type_str := arg_type_to_odin_type(arg, enums_pkg)
					defer delete(type_str)
					fmt.sbprintf(
						sb,
						"\t\t%s := transmute(%s)(buf_reader.read_u32(msg, msg_len))\n",
						arg.name,
						type_str,
					)
				case arg.type == "uint", arg.type == "object", arg.type == "new_id":
					fmt.sbprintf(sb, "\t\t%s := buf_reader.read_u32(msg, msg_len)\n", arg.name)
				case arg.type == "int":
					fmt.sbprintf(sb, "\t\t%s := buf_reader.read_i32(msg, msg_len)\n", arg.name)
				case arg.type == "fixed":
					fmt.sbprintf(sb, "\t\t%s := buf_reader.read_fixed(msg, msg_len)\n", arg.name)
				case arg.type == "string":
					fmt.sbprintf(sb, "\t\t%s := buf_reader.read_string(msg, msg_len)\n", arg.name)
					fmt.sbprintf(sb, "\t\tdefer delete(%s)\n", arg.name)
				case arg.type == "array":
					fmt.sbprintf(sb, "\t\t%s := buf_reader.read_array(msg, msg_len)\n", arg.name)
					fmt.sbprintf(sb, "\t\tdefer delete(%s)\n", arg.name)
				}
			}

			if first_print_arg {
				fmt.sbprintf(&print_fmt_sb, "%s=%%v", arg.name)
				first_print_arg = false
			} else {
				fmt.sbprintf(&print_fmt_sb, " %s=%%v", arg.name)
			}
			fmt.sbprintf(&print_args_sb, ", %s", arg.name)
			fmt.sbprintf(&call_args_sb, "%s, ", arg.name)
		}

		print_fmt := strings.to_string(print_fmt_sb)
		separator := " " if len(print_fmt) > 0 else ""
		fmt.sbprintf(
			sb,
			"\t\tfmt.printfln(\"<- %s@%%v.%s: %s%s[%%s]\", object_id%s, \"handled\" if handlers.on_%s != nil else \"unhandled\")\n",
			iface.name,
			ev.name,
			print_fmt,
			separator,
			strings.to_string(print_args_sb),
			ev.name,
		)
		fmt.sbprintf(sb, "\t\tif handlers.on_%s != nil {{\n", ev.name)
		fmt.sbprintf(
			sb,
			"\t\t\terr := handlers.on_%s(object_id, %suser_data)\n",
			ev.name,
			strings.to_string(call_args_sb),
		)
		strings.write_string(sb, "\t\t\tif err != nil do return err\n")
		strings.write_string(sb, "\t\t}\n")
	}

	strings.write_string(sb, "\t}\n")
	strings.write_string(sb, "\treturn nil\n")
	strings.write_string(sb, "}\n")
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

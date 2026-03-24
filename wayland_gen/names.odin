package wayland_gen

import "core:strings"
import "core:unicode"

// wl_surface -> WL_SURFACE, attach -> ATTACH
// Caller owns returned string.
to_upper_snake :: proc(s: string) -> string {
	sb: strings.Builder
	strings.builder_init(&sb)
	for ch in s {
		if ch == '-' {
			strings.write_byte(&sb, '_')
		} else {
			strings.write_rune(&sb, unicode.to_upper(ch))
		}
	}
	// builder_to_string transfers ownership; no defer destroy needed
	return strings.to_string(sb)
}

// pixel_format -> PixelFormat, argb_8888 -> Argb8888
// Caller owns returned string.
to_camel_case :: proc(s: string) -> string {
	sb: strings.Builder
	strings.builder_init(&sb)

	capitalise_next := true
	for ch in s {
		if ch == '_' || ch == '-' {
			capitalise_next = true
			continue
		}
		if capitalise_next {
			strings.write_rune(&sb, unicode.to_upper(ch))
			capitalise_next = false
		} else {
			strings.write_rune(&sb, ch)
		}
	}
	return strings.to_string(sb)
}

// Format a single arg as a comment line, e.g.:
//   "id: new_id wl_subsurface = the new sub-surface object ID"
// Caller owns returned string.
format_arg_comment :: proc(arg: Arg) -> string {
	sb: strings.Builder
	strings.builder_init(&sb)

	strings.write_string(&sb, arg.name)
	strings.write_string(&sb, ": ")
	strings.write_string(&sb, arg.type)

	if arg.type == "new_id" || arg.type == "object" {
		strings.write_byte(&sb, ' ')
		if arg.interface != "" {
			strings.write_string(&sb, arg.interface)
		} else {
			strings.write_string(&sb, "<unknown>")
		}
	}

	strings.write_string(&sb, " = ")
	strings.write_string(&sb, arg.summary)

	return strings.to_string(sb)
}

// Emit all arg comment lines for placement above an arg count constant.
// Returns empty string if no args.
// Caller owns returned string.
format_arg_comments :: proc(args: [dynamic]Arg) -> string {
	if len(args) == 0 do return ""

	sb: strings.Builder
	strings.builder_init(&sb)

	for arg, i in args {
		if i > 0 do strings.write_byte(&sb, '\n')
		strings.write_string(&sb, "// ")
		line := format_arg_comment(arg)
		strings.write_string(&sb, line)
		delete(line)
	}

	return strings.to_string(sb)
}

// Wrap a Description into // comment lines:
//   summary line, blank //, then body lines (body section omitted if empty).
// If desc is nil, returns "// (description not found)".
// Caller owns returned string.
format_description_comment :: proc(desc: Maybe(Description)) -> string {
	sb: strings.Builder
	strings.builder_init(&sb)

	d, has_desc := desc.(Description)
	if !has_desc {
		strings.write_string(&sb, "// (description not found)")
		return strings.to_string(sb)
	}

	if d.summary != "" {
		strings.write_string(&sb, "// ")
		strings.write_string(&sb, d.summary)
	} else {
		strings.write_string(&sb, "//")
	}

	if d.body != "" {
		strings.write_string(&sb, "\n//")
		lines := strings.split_lines(d.body)
		defer delete(lines)
		for line in lines {
			strings.write_string(&sb, "\n// ")
			strings.write_string(&sb, line)
		}
	}

	return strings.to_string(sb)
}

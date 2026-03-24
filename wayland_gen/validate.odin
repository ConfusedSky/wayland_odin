package wayland_gen

import "core:fmt"

ODIN_KEYWORDS :: []string {
	"align_of",
	"auto_cast",
	"bit_set",
	"break",
	"case",
	"cast",
	"context",
	"continue",
	"defer",
	"distinct",
	"do",
	"dynamic",
	"else",
	"enum",
	"fallthrough",
	"false",
	"for",
	"foreign",
	"if",
	"import",
	"in",
	"inline",
	"map",
	"matrix",
	"nil",
	"not_in",
	"offset_of",
	"opaque",
	"or_else",
	"or_return",
	"package",
	"proc",
	"return",
	"size_of",
	"struct",
	"switch",
	"transmute",
	"true",
	"type_of",
	"typeid",
	"union",
	"using",
	"when",
	"where",
}

is_keyword :: proc(s: string) -> bool {
	for kw in ODIN_KEYWORDS {
		if s == kw do return true
	}
	return false
}

// Returns true if all identifiers are clean, false (with printed errors) otherwise.
validate_protocol :: proc(p: ^Protocol) -> bool {
	all_ok := true

	for &iface in p.interfaces {
		// Interface name itself becomes a package name — check it
		if is_keyword(iface.name) {
			fmt.eprintf(
				"Error: interface name '%s' collides with an Odin reserved keyword\n",
				iface.name,
			)
			all_ok = false
		}

		for &req in iface.requests {
			for &arg in req.args {
				if is_keyword(arg.name) {
					fmt.eprintf(
						"Error: arg '%s' on request '%s' in interface '%s' collides with an Odin reserved keyword\n",
						arg.name,
						req.name,
						iface.name,
					)
					all_ok = false
				}
			}
		}

		for &ev in iface.events {
			for &arg in ev.args {
				if is_keyword(arg.name) {
					fmt.eprintf(
						"Error: arg '%s' on event '%s' in interface '%s' collides with an Odin reserved keyword\n",
						arg.name,
						ev.name,
						iface.name,
					)
					all_ok = false
				}
			}
		}
	}

	return all_ok
}

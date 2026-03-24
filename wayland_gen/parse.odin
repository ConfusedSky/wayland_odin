package wayland_gen

import "core:encoding/xml"
import "core:fmt"
import "core:strings"

parse_protocol :: proc(data: []byte) -> (protocol: Protocol, ok: bool) {
	doc, err := xml.parse(data, xml.Options{flags = {.Ignore_Unsupported}, expected_doctype = ""})
	if err != .None {
		fmt.eprintf("Error: failed to parse XML: %v\n", err)
		return {}, false
	}
	defer xml.destroy(doc)

	if len(doc.elements) == 0 {
		fmt.eprintln("Error: XML document has no elements")
		return {}, false
	}

	// Root element is always elements[0]
	root := &doc.elements[0]
	if root.ident != "protocol" {
		fmt.eprintf("Error: root element is '%s', expected 'protocol'\n", root.ident)
		return {}, false
	}

	proto_name, name_ok := attr(root, "name")
	if !name_ok {
		fmt.eprintln("Error: <protocol> missing required attribute 'name'")
		return {}, false
	}
	protocol.name = strings.clone(proto_name)

	// Children are embedded in element.value as Element_ID entries
	for v in root.value {
		child_id, is_elem := v.(xml.Element_ID)
		if !is_elem do continue

		child := &doc.elements[child_id]
		if child.ident != "interface" do continue

		iface, iface_ok := parse_interface(doc, child_id)
		if !iface_ok do return {}, false
		append(&protocol.interfaces, iface)
	}

	return protocol, true
}

parse_interface :: proc(doc: ^xml.Document, id: xml.Element_ID) -> (iface: Interface, ok: bool) {
	elem := &doc.elements[id]

	name, name_ok := attr(elem, "name")
	if !name_ok {
		fmt.eprintln("Error: <interface> missing required attribute 'name'")
		return {}, false
	}
	iface.name = strings.clone(name)

	version, _ := attr(elem, "version")
	iface.version = strings.clone(version)

	request_idx := 0
	event_idx := 0

	for v in elem.value {
		child_id, is_elem := v.(xml.Element_ID)
		if !is_elem do continue

		child := &doc.elements[child_id]
		switch child.ident {
		case "description":
			desc, desc_ok := parse_description(doc, child_id)
			if !desc_ok do return {}, false
			iface.description = desc
		case "request":
			req, req_ok := parse_request(doc, child_id, request_idx, iface.name)
			if !req_ok do return {}, false
			append(&iface.requests, req)
			request_idx += 1
		case "event":
			ev, ev_ok := parse_event(doc, child_id, event_idx, iface.name)
			if !ev_ok do return {}, false
			append(&iface.events, ev)
			event_idx += 1
		case "enum":
			en, en_ok := parse_enum(doc, child_id, iface.name)
			if !en_ok do return {}, false
			append(&iface.enums, en)
		}
	}

	return iface, true
}

parse_request :: proc(
	doc: ^xml.Document,
	id: xml.Element_ID,
	opcode: int,
	iface_name: string,
) -> (
	req: Request,
	ok: bool,
) {
	elem := &doc.elements[id]

	name, name_ok := attr(elem, "name")
	if !name_ok {
		fmt.eprintf(
			"Error: <request> in interface '%s' missing required attribute 'name'\n",
			iface_name,
		)
		return {}, false
	}
	req.name = strings.clone(name)
	req.opcode = opcode

	for v in elem.value {
		child_id, is_elem := v.(xml.Element_ID)
		if !is_elem do continue

		child := &doc.elements[child_id]
		switch child.ident {
		case "description":
			desc, desc_ok := parse_description(doc, child_id)
			if !desc_ok do return {}, false
			req.description = desc
		case "arg":
			arg, arg_ok := parse_arg(doc, child_id, req.name, iface_name)
			if !arg_ok do return {}, false
			append(&req.args, arg)
		}
	}

	return req, true
}

parse_event :: proc(
	doc: ^xml.Document,
	id: xml.Element_ID,
	opcode: int,
	iface_name: string,
) -> (
	ev: Event,
	ok: bool,
) {
	elem := &doc.elements[id]

	name, name_ok := attr(elem, "name")
	if !name_ok {
		fmt.eprintf(
			"Error: <event> in interface '%s' missing required attribute 'name'\n",
			iface_name,
		)
		return {}, false
	}
	ev.name = strings.clone(name)
	ev.opcode = opcode

	for v in elem.value {
		child_id, is_elem := v.(xml.Element_ID)
		if !is_elem do continue

		child := &doc.elements[child_id]
		switch child.ident {
		case "description":
			desc, desc_ok := parse_description(doc, child_id)
			if !desc_ok do return {}, false
			ev.description = desc
		case "arg":
			arg, arg_ok := parse_arg(doc, child_id, ev.name, iface_name)
			if !arg_ok do return {}, false
			append(&ev.args, arg)
		}
	}

	return ev, true
}

parse_arg :: proc(
	doc: ^xml.Document,
	id: xml.Element_ID,
	parent_name: string,
	iface_name: string,
) -> (
	arg: Arg,
	ok: bool,
) {
	elem := &doc.elements[id]

	name, name_ok := attr(elem, "name")
	if !name_ok {
		fmt.eprintf(
			"Error: <arg> in '%s.%s' missing required attribute 'name'\n",
			iface_name,
			parent_name,
		)
		return {}, false
	}
	type, type_ok := attr(elem, "type")
	if !type_ok {
		fmt.eprintf(
			"Error: <arg '%s'> in '%s.%s' missing required attribute 'type'\n",
			name,
			iface_name,
			parent_name,
		)
		return {}, false
	}

	arg.name = strings.clone(name)
	arg.type = strings.clone(type)

	iface_attr, has_iface := attr(elem, "interface")
	if has_iface do arg.interface = strings.clone(iface_attr)

	enum_attr, has_enum := attr(elem, "enum")
	if has_enum do arg.enum_ref = strings.clone(enum_attr)

	summary, has_summary := attr(elem, "summary")
	if has_summary do arg.summary = strings.clone(summary)

	return arg, true
}

parse_enum :: proc(
	doc: ^xml.Document,
	id: xml.Element_ID,
	iface_name: string,
) -> (
	en: Enum,
	ok: bool,
) {
	elem := &doc.elements[id]

	name, name_ok := attr(elem, "name")
	if !name_ok {
		fmt.eprintf(
			"Error: <enum> in interface '%s' missing required attribute 'name'\n",
			iface_name,
		)
		return {}, false
	}
	en.name = strings.clone(name)

	bitfield_str, _ := attr(elem, "bitfield")
	en.bitfield = bitfield_str == "true"

	for v in elem.value {
		child_id, is_elem := v.(xml.Element_ID)
		if !is_elem do continue

		child := &doc.elements[child_id]
		switch child.ident {
		case "description":
			desc, desc_ok := parse_description(doc, child_id)
			if !desc_ok do return {}, false
			en.description = desc
		case "entry":
			entry, entry_ok := parse_enum_entry(doc, child_id, en.name, iface_name)
			if !entry_ok do return {}, false
			append(&en.entries, entry)
		}
	}

	return en, true
}

parse_enum_entry :: proc(
	doc: ^xml.Document,
	id: xml.Element_ID,
	enum_name: string,
	iface_name: string,
) -> (
	entry: EnumEntry,
	ok: bool,
) {
	elem := &doc.elements[id]

	name, name_ok := attr(elem, "name")
	if !name_ok {
		fmt.eprintf(
			"Error: <entry> in enum '%s.%s' missing required attribute 'name'\n",
			iface_name,
			enum_name,
		)
		return {}, false
	}
	value, value_ok := attr(elem, "value")
	if !value_ok {
		fmt.eprintf(
			"Error: <entry '%s'> in enum '%s.%s' missing required attribute 'value'\n",
			name,
			iface_name,
			enum_name,
		)
		return {}, false
	}

	entry.name = strings.clone(name)
	entry.value = strings.clone(value)

	summary, has_summary := attr(elem, "summary")
	if has_summary do entry.summary = strings.clone(summary)

	return entry, true
}

parse_description :: proc(
	doc: ^xml.Document,
	id: xml.Element_ID,
) -> (
	desc: Description,
	ok: bool,
) {
	elem := &doc.elements[id]

	summary, has_summary := attr(elem, "summary")
	if has_summary do desc.summary = strings.clone(summary)

	// Text content is in element.value as string entries (interleaved with child Element_IDs)
	sb: strings.Builder
	strings.builder_init(&sb)
	defer strings.builder_destroy(&sb)

	for v in elem.value {
		text, is_text := v.(string)
		if is_text {
			strings.write_string(&sb, text)
		}
	}

	desc.body = normalize_description_body(strings.to_string(sb))
	return desc, true
}

// Trim leading/trailing blank lines and normalise internal indentation
normalize_description_body :: proc(s: string) -> string {
	lines := strings.split_lines(s)
	defer delete(lines)

	trimmed := make([dynamic]string, 0, len(lines))
	defer delete(trimmed)

	started := false
	for line in lines {
		t := strings.trim_space(line)
		if !started && t == "" do continue
		started = true
		append(&trimmed, t)
	}

	// Strip trailing blank lines
	end := len(trimmed)
	for end > 0 && trimmed[end - 1] == "" {
		end -= 1
	}

	sb: strings.Builder
	strings.builder_init(&sb)
	for i in 0 ..< end {
		if i > 0 do strings.write_byte(&sb, '\n')
		strings.write_string(&sb, trimmed[i])
	}

	return strings.to_string(sb)
}

// Get an attribute value by name from an element
attr :: proc(elem: ^xml.Element, name: string) -> (value: string, ok: bool) {
	for a in elem.attribs {
		if a.key == name {
			return a.val, true
		}
	}
	return "", false
}

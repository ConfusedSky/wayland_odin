package Main

import buf_writer "./buf_writer"
import constants "./constants"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import wl_display "wayland_protocol/wl_display"
import wl_registry "wayland_protocol/wl_registry"

// registry_bind sends the full wl_registry.bind wire message including the
// interface string and version, which are required for the untyped new_id arg.
// The generated wl_registry.bind does not yet handle this special case.
// interface must not include a null terminator; registry_bind appends one.
registry_bind :: proc(
	socket: linux.Fd,
	registry: u32,
	name: u32,
	interface: string,
	version: u32,
	new_id: u32,
) -> u32 {
	writer: buf_writer.Writer(constants.BUF_WRITER_SIZE_STRING)
	buf_writer.initialize(&writer, registry, wl_registry.BIND_REQUEST_OPCODE)
	buf_writer.write_u32(&writer, name)
	// Wayland strings include null terminator in the length field
	interface_wire := strings.concatenate({interface, "\x00"})
	defer delete(interface_wire)
	buf_writer.write_string(&writer, interface_wire)
	buf_writer.write_u32(&writer, version)
	buf_writer.write_u32(&writer, new_id)
	send_err := buf_writer.send(&writer, socket)
	if send_err != nil do os.exit(int(send_err))
	fmt.printfln(
		"-> wl_registry@%v.bind: name=%v interface=%v version=%v id=%v",
		registry,
		name,
		interface,
		version,
		new_id,
	)
	return new_id
}

initialize_wl_registry :: proc(state: ^state_t) {
	assert(state.socket_fd > 0)

	state.wayland_current_id += 1
	err := wl_display.get_registry(
		state.socket_fd,
		constants.WAYLAND_DISPLAY_OBJECT_ID,
		state.wayland_current_id,
	)
	if err != nil do os.exit(int(err))
	state.wl_registry = state.wayland_current_id
	register_event_handler(
		state,
		state.wl_registry,
		&wl_registry_handlers,
		wl_registry.handle_event,
	)
}

initialize_wl_compositor :: proc(state: ^state_t, name: u32, version: u32) {
	state.wayland_current_id += 1
	state.wl_compositor = registry_bind(
		state.socket_fd,
		state.wl_registry,
		name,
		"wl_compositor",
		version,
		state.wayland_current_id,
	)
}

on_wl_registry_global :: proc(
	_: u32,
	name: u32,
	interface: string,
	version: u32,
	user_data: rawptr,
) {
	state := (^state_t)(user_data)
	if interface == "wl_shm" {
		initialize_wl_shm(state, name, version)
	} else if interface == "wl_output" {
		initialize_wl_output(state, name, version)
	} else if interface == "xdg_wm_base" {
		initialize_xdg_wm_base(state, name, version)
	} else if interface == "wl_compositor" {
		initialize_wl_compositor(state, name, version)
	}
}

wl_registry_handlers := wl_registry.EventHandlers {
	on_global = on_wl_registry_global,
}

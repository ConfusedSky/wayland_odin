package Main

import buf_writer "./buf_writer"
import constants "./constants"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import wl_compositor "wayland_protocol/wl_compositor"
import wl_display "wayland_protocol/wl_display"
import wl_output "wayland_protocol/wl_output"
import wl_registry "wayland_protocol/wl_registry"
import wl_shm "wayland_protocol/wl_shm"
import xdg_wm_base "wayland_protocol/xdg_wm_base"

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

initialize_registry :: proc(state: ^state_t) {
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

_on_wl_registry_global :: proc(
	_: u32,
	name: u32,
	interface: string,
	version: u32,
	user_data: rawptr,
) {
	state := (^state_t)(user_data)
	if interface == "wl_shm" {
		state.wayland_current_id += 1
		state.wl_shm = registry_bind(
			state.socket_fd,
			state.wl_registry,
			name,
			interface,
			version,
			state.wayland_current_id,
		)
		register_event_handler(state, state.wl_shm, &wl_shm_handlers, wl_shm.handle_event)
	} else if interface == "wl_output" {
		state.wayland_current_id += 1
		output := Output {
			object_id = registry_bind(
				state.socket_fd,
				state.wl_registry,
				name,
				interface,
				version,
				state.wayland_current_id,
			),
			is_done   = false,
		}
		assert(state.wl_output_count < constants.MAX_OUTPUTS)
		state.wl_output[state.wl_output_count] = output
		state.wl_output_count += 1
		output_user_data := new(OutputUserData)
		output_user_data^ = OutputUserData {
			state  = state,
			output = &state.wl_output[state.wl_output_count - 1],
		}
		register_event_handler(
			state,
			output.object_id,
			&wl_output_handlers,
			wl_output.handle_event,
			output_user_data,
		)
	} else if interface == "xdg_wm_base" {
		state.wayland_current_id += 1
		state.xdg_wm_base = registry_bind(
			state.socket_fd,
			state.wl_registry,
			name,
			interface,
			version,
			state.wayland_current_id,
		)
		register_event_handler(
			state,
			state.xdg_wm_base,
			&xdg_wm_base_handlers,
			xdg_wm_base.handle_event,
		)
	} else if interface == "wl_compositor" {
		state.wayland_current_id += 1
		state.wl_compositor = registry_bind(
			state.socket_fd,
			state.wl_registry,
			name,
			interface,
			version,
			state.wayland_current_id,
		)
	}
}

wl_registry_handlers := wl_registry.EventHandlers {
	on_global = _on_wl_registry_global,
}

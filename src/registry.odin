package Main

import "core:os"
import wl_compositor "wayland_protocol/wl_compositor"
import wl_display "wayland_protocol/wl_display"
import wl_registry "wayland_protocol/wl_registry"

initialize_wl_registry :: proc(state: ^state_t) {
	assert(state.wl_display.socket > 0)

	registry, err := wl_display.get_registry(&state.wl_display)
	if err != nil do os.exit(int(err))
	state.wl_registry = registry
	register_event_handler(
		state,
		state.wl_registry.id,
		&wl_registry_handlers,
		wl_registry.handle_event,
	)
}

initialize_wl_compositor :: proc(state: ^state_t, name: u32, version: u32) {
	compositor, err := wl_compositor.from_global(&state.wl_registry, name, version)
	if err != nil do os.exit(int(err))
	state.wl_compositor = compositor
}

on_wl_registry_global :: proc(
	_: u32,
	name: u32,
	interface: string,
	version: u32,
	user_data: rawptr,
) {
	state := (^state_t)(user_data)
	switch interface {
	case "wl_seat":
		initialize_seat(state, name, version)
	case "wl_shm":
		initialize_wl_shm(state, name, version)
	case "wl_output":
		initialize_wl_output(state, name, version)
	case "xdg_wm_base":
		initialize_xdg_wm_base(state, name, version)
	case "wl_compositor":
		initialize_wl_compositor(state, name, version)
	}
}

wl_registry_handlers := wl_registry.EventHandlers {
	on_global = on_wl_registry_global,
}

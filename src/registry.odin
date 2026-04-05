package Main

import wl_compositor "wayland_protocol/wl_compositor"
import wl_display "wayland_protocol/wl_display"
import wl_registry "wayland_protocol/wl_registry"

initialize_wl_registry :: proc(state: ^state_t) -> Errno {
	assert(state.wl_display.socket > 0)
	state.wl_registry = wl_display.get_registry(&state.wl_display) or_return
	register_event_handler(
		state,
		state.wl_registry.id,
		&wl_registry_handlers,
		wl_registry.handle_event,
	)
	return nil
}

initialize_wl_compositor :: proc(state: ^state_t, name: u32, version: u32) -> Errno {
	state.wl_compositor = wl_compositor.from_global(&state.wl_registry, name, version) or_return
	return nil
}

on_wl_registry_global :: proc(
	_: u32,
	name: u32,
	interface: string,
	version: u32,
	user_data: rawptr,
) {
	state := (^state_t)(user_data)
	err: Errno
	switch interface {
	case "wl_seat":
		err = initialize_seat(state, name, version)
	case "wl_shm":
		err = initialize_wl_shm(state, name, version)
	case "wl_output":
		err = initialize_wl_output(state, name, version)
	case "xdg_wm_base":
		err = initialize_xdg_wm_base(state, name, version)
	case "wl_compositor":
		err = initialize_wl_compositor(state, name, version)
	}
	if err != nil {
		state.last_err = err
	}
}

wl_registry_handlers := wl_registry.EventHandlers {
	on_global = on_wl_registry_global,
}

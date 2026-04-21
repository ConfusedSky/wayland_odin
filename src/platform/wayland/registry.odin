package wayland

import wl_compositor "../../wayland_protocol/wl_compositor"
import wl_display "../../wayland_protocol/wl_display"
import wl_registry "../../wayland_protocol/wl_registry"

initialize_wl_registry :: proc(client: ^Client) -> Errno {
	assert(client.wl_display.socket > 0)
	client.wl_registry = wl_display.get_registry(&client.wl_display) or_return
	register_event_handler(
		client,
		client.wl_registry.id,
		&wl_registry_handlers,
		wl_registry.handle_event,
	)
	return nil
}

initialize_wl_compositor :: proc(client: ^Client, name: u32, version: u32) -> Errno {
	client.wl_compositor = wl_compositor.from_global(&client.wl_registry, name, version) or_return
	return nil
}

on_wl_registry_global :: proc(
	_: u32,
	name: u32,
	interface: string,
	version: u32,
	user_data: rawptr,
) -> Errno {
	client := (^Client)(user_data)
	switch interface {
	case "wl_seat":
		return initialize_seat(client, name, version)
	case "wl_shm":
		return initialize_wl_shm(client, name, version)
	case "wl_output":
		return initialize_wl_output(client, name, version)
	case "xdg_wm_base":
		return initialize_xdg_wm_base(client, name, version)
	case "wl_compositor":
		return initialize_wl_compositor(client, name, version)
	case "zwp_linux_dmabuf_v1":
		return initialize_zwp_linux_dmabuf(client, name, version)
	}
	return nil
}

wl_registry_handlers := wl_registry.EventHandlers {
	on_global = on_wl_registry_global,
}

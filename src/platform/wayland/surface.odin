package wayland

import renderer "../../renderer"
import wl_buffer "../../wayland_protocol/wl_buffer"
import wl_callback "../../wayland_protocol/wl_callback"
import wl_compositor "../../wayland_protocol/wl_compositor"
import wl_surface "../../wayland_protocol/wl_surface"
import xdg_surface "../../wayland_protocol/xdg_surface"
import xdg_toplevel "../../wayland_protocol/xdg_toplevel"
import xdg_wm_base "../../wayland_protocol/xdg_wm_base"

wl_surface_handlers: wl_surface.EventHandlers

xdg_wm_base_handlers := xdg_wm_base.EventHandlers {
	on_ping = proc(_: u32, serial: u32, user_data: rawptr) -> Errno {
		client := (^Client)(user_data)
		return xdg_wm_base.pong(&client.xdg_wm_base, serial)
	},
}

xdg_toplevel_handlers := xdg_toplevel.EventHandlers {
	on_close = proc(_: u32, user_data: rawptr) -> Errno {
		client := (^Client)(user_data)
		client.running = false
		return nil
	},
	on_configure = proc(
		_: u32,
		width: i32,
		height: i32,
		states: []u8,
		user_data: rawptr,
	) -> Errno {
		client := (^Client)(user_data)
		if width < client.min_w || height < client.min_h {
			client.width = u32(client.min_w)
			client.height = u32(client.min_h)
			return nil
		}
		client.width = u32(width)
		client.height = u32(height)
		return nil
	},
}

xdg_surface_handlers := xdg_surface.EventHandlers {
	on_configure = proc(_: u32, serial: u32, user_data: rawptr) -> Errno {
		client := (^Client)(user_data)
		xdg_surface.ack_configure(&client.xdg_surface, serial) or_return
		client.surface_state = .ACKED_CONFIGURE
		return nil
	},
}

initialize_xdg_wm_base :: proc(client: ^Client, name: u32, version: u32) -> Errno {
	client.xdg_wm_base = xdg_wm_base.from_global(&client.wl_registry, name, version) or_return
	register_event_handler(
		client,
		client.xdg_wm_base.id,
		&xdg_wm_base_handlers,
		xdg_wm_base.handle_event,
	)
	return nil
}

initialize_wl_surface :: proc(client: ^Client) -> Errno {
	client.wl_surface = wl_compositor.create_surface(&client.wl_compositor) or_return
	register_event_handler(
		client,
		client.wl_surface.id,
		&wl_surface_handlers,
		wl_surface.handle_event,
	)
	return nil
}

initialize_xdg_surface :: proc(client: ^Client) -> Errno {
	client.xdg_surface = xdg_wm_base.get_xdg_surface(
		&client.xdg_wm_base,
		&client.wl_surface,
	) or_return
	register_event_handler(
		client,
		client.xdg_surface.id,
		&xdg_surface_handlers,
		xdg_surface.handle_event,
	)
	return nil
}

initialize_xdg_toplevel :: proc(client: ^Client) -> Errno {
	client.xdg_toplevel = xdg_surface.get_toplevel(&client.xdg_surface) or_return
	register_event_handler(
		client,
		client.xdg_toplevel.id,
		&xdg_toplevel_handlers,
		xdg_toplevel.handle_event,
	)
	return nil
}

can_initialize_surface :: proc(client: ^Client) -> bool {
	return(
		client.cursor.initialized &&
		client.max_width > 0 &&
		client.max_height > 0 &&
		client.wl_compositor.id != 0 &&
		client.zwp_linux_dmabuf.id != 0 &&
		client.xdg_wm_base.id != 0 &&
		client.wl_surface.id == 0 \
	)
}

initialize_surface :: proc(client: ^Client) -> Errno {
	assert(client.surface_state == .NONE)
	initialize_wl_surface(client) or_return
	initialize_xdg_surface(client) or_return
	initialize_xdg_toplevel(client) or_return
	xdg_toplevel.set_min_size(&client.xdg_toplevel, client.min_w, client.min_h) or_return
	wl_surface.commit(&client.wl_surface) or_return
	client.buffer_ready = true
	return nil
}

initialize_buffer :: proc(
	client: ^Client,
	buf: ^renderer.VulkanFrameBuffer,
	width: u32,
	height: u32,
) -> Errno {
	if client.wl_buffer.id != 0 {
		wl_buffer.destroy(&client.wl_buffer) or_return
	}
	client.wl_buffer = import_as_wl_buffer(client, buf, width, height) or_return
	register_event_handler(
		client,
		client.wl_buffer.id,
		&wl_buffer_handlers,
		wl_buffer.handle_event,
	)
	client.buf_width = width
	client.buf_height = height
	return nil
}

present_dmabuf :: proc(client: ^Client, buf: ^renderer.VulkanFrameBuffer) -> Errno {
	assert(client.wl_surface.id != 0)
	assert(client.xdg_surface.id != 0)
	assert(client.xdg_toplevel.id != 0)
	assert(buf.memory != 0)
	assert(client.width > 0 && client.height > 0)
	assert(client.buffer_ready)

	if client.width != client.buf_width || client.height != client.buf_height {
		initialize_buffer(client, buf, client.width, client.height) or_return
	}

	wl_surface.attach(&client.wl_surface, &client.wl_buffer, 0, 0) or_return
	wl_surface.damage_buffer(
		&client.wl_surface,
		0,
		0,
		i32(client.width),
		i32(client.height),
	) or_return

	frame_cb := wl_surface.frame(&client.wl_surface) or_return
	register_event_handler(client, frame_cb.id, &wl_callback_handlers, wl_callback.handle_event)

	client.buffer_ready = false
	wl_surface.commit(&client.wl_surface) or_return

	client.surface_state = .ATTACHED
	return nil
}

package wayland

import constants "../../constants"
import wl_buffer "../../wayland_protocol/wl_buffer"
import wl_compositor "../../wayland_protocol/wl_compositor"
import wl_display "../../wayland_protocol/wl_display"
import wl_keyboard "../../wayland_protocol/wl_keyboard"
import wl_pointer "../../wayland_protocol/wl_pointer"
import wl_registry "../../wayland_protocol/wl_registry"
import wl_seat "../../wayland_protocol/wl_seat"
import wl_shm "../../wayland_protocol/wl_shm"
import wl_surface "../../wayland_protocol/wl_surface"
import xdg_surface "../../wayland_protocol/xdg_surface"
import xdg_toplevel "../../wayland_protocol/xdg_toplevel"
import xdg_wm_base "../../wayland_protocol/xdg_wm_base"
import zwp_linux_dmabuf_v1 "../../wayland_protocol/zwp_linux_dmabuf_v1"
import "core:sys/linux"

Errno :: linux.Errno

Surface_State :: enum {
	NONE,
	ACKED_CONFIGURE,
	ATTACHED,
}

Init_Params :: struct {
	title: string,
	min_w: i32,
	min_h: i32,
}

Frame_Info :: struct {
	width:     u32,
	height:    u32,
	pointer_x: f64,
	pointer_y: f64,
}

Client :: struct {
	cursor:           Cursor,
	wl_display:       wl_display.t,
	wl_registry:      wl_registry.t,
	wl_seat:          wl_seat.t,
	wl_keyboard:      wl_keyboard.t,
	wl_pointer:       wl_pointer.t,
	pointer:          Pointer,
	wl_shm:           wl_shm.t,
	zwp_linux_dmabuf: zwp_linux_dmabuf_v1.t,
	wl_buffer:        wl_buffer.t,
	buffer_ready:     bool,
	xdg_wm_base:      xdg_wm_base.t,
	xdg_surface:      xdg_surface.t,
	wl_compositor:    wl_compositor.t,
	wl_surface:       wl_surface.t,
	outputs:          [constants.MAX_OUTPUTS]Output,
	output_count:     int,
	xdg_toplevel:     xdg_toplevel.t,
	width:            u32,
	max_width:        u32,
	height:           u32,
	max_height:       u32,
	buf_width:        u32,
	buf_height:       u32,
	surface_state:    Surface_State,
	event_handlers:   [dynamic]RegisteredEventHandler,
	last_err:         Errno,
	running:          bool,
	min_w:            i32,
	min_h:            i32,
}

HandleEventProc :: proc(
	object_id: u32,
	opcode: u16,
	msg: ^^u8,
	msg_len: ^int,
	handlers_raw: rawptr,
	user_data: rawptr,
	fds: ^[]linux.Fd,
)

RegisteredEventHandler :: struct {
	event_handlers: rawptr,
	handle_event:   HandleEventProc,
	object_id:      u32,
	user_data:      rawptr,
}

register_event_handler :: proc(
	client: ^Client,
	object_id: u32,
	event_handlers: rawptr,
	handle_event: HandleEventProc,
	user_data: rawptr = nil,
) {
	assert(
		len(client.event_handlers) == 0 ||
		object_id > client.event_handlers[len(client.event_handlers) - 1].object_id,
	)
	append(
		&client.event_handlers,
		RegisteredEventHandler {
			event_handlers = event_handlers,
			object_id = object_id,
			handle_event = handle_event,
			user_data = user_data if user_data != nil else client,
		},
	)
}

unregister_event_handler :: proc(client: ^Client, object_id: u32) {
	idx, found := find_event_handler(client.event_handlers[:], object_id)
	if !found do return
	handler := client.event_handlers[idx]
	if handler.user_data != rawptr(client) {
		free(handler.user_data)
	}
	ordered_remove(&client.event_handlers, idx)
}

find_event_handler :: proc(handlers: []RegisteredEventHandler, object_id: u32) -> (int, bool) {
	lo, hi := 0, len(handlers)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		mid_id := handlers[mid].object_id
		if mid_id == object_id {
			return mid, true
		} else if mid_id < object_id {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return 0, false
}

init :: proc(client: ^Client, params: Init_Params) -> Errno {
	client.running = true
	client.min_w = params.min_w
	client.min_h = params.min_h
	initialize_display(client) or_return
	initialize_wl_registry(client) or_return
	return nil
}

pump :: proc(client: ^Client) -> Errno {
	wayland_handle_messages(client) or_return
	if !client.cursor.initialized && client.wl_compositor.id > 0 && client.wl_shm.id > 0 {
		initialize_cursor(&client.wl_compositor, &client.wl_shm, &client.cursor) or_return
	}
	if can_initialize_surface(client) {
		initialize_surface(client) or_return
	}
	return client.last_err
}

should_close :: proc(client: ^Client) -> bool {
	return !client.running
}

ready_for_frame :: proc(client: ^Client) -> bool {
	return client.buffer_ready && client.surface_state == .ACKED_CONFIGURE
}

frame_info :: proc(client: ^Client) -> Frame_Info {
	return Frame_Info {
		width = client.width,
		height = client.height,
		pointer_x = client.pointer.surface_x,
		pointer_y = client.pointer.surface_y,
	}
}

max_surface_size :: proc(client: ^Client) -> (u32, u32) {
	return client.max_width, client.max_height
}

skip_frame :: proc(client: ^Client) {
	client.surface_state = .ATTACHED
}

shutdown :: proc(client: ^Client) -> Errno {
	for len(client.event_handlers) > 0 {
		unregister_event_handler(client, client.event_handlers[0].object_id)
	}
	delete(client.event_handlers)
	if client.cursor.initialized {
		cleanup_cursor(&client.cursor) or_return
	}
	wayland_display_connection_cleanup(client.wl_display.socket) or_return
	return nil
}

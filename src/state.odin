package Main

import constants "./constants"
import "core:sys/linux"
import wl_buffer "wayland_protocol/wl_buffer"
import wl_compositor "wayland_protocol/wl_compositor"
import wl_display "wayland_protocol/wl_display"
import wl_keyboard "wayland_protocol/wl_keyboard"
import wl_pointer "wayland_protocol/wl_pointer"
import wl_registry "wayland_protocol/wl_registry"
import wl_seat "wayland_protocol/wl_seat"
import wl_shm "wayland_protocol/wl_shm"
import wl_shm_pool "wayland_protocol/wl_shm_pool"
import wl_surface "wayland_protocol/wl_surface"
import xdg_surface "wayland_protocol/xdg_surface"
import xdg_toplevel "wayland_protocol/xdg_toplevel"
import xdg_wm_base "wayland_protocol/xdg_wm_base"

state_state_t :: enum {
	STATE_NONE,
	STATE_SURFACE_ACKED_CONFIGURE,
	STATE_SURFACE_ATTACHED,
}

state_t :: struct {
	wl_display:      wl_display.t,
	wl_registry:     wl_registry.t,
	wl_seat:         wl_seat.t,
	wl_keyboard:     wl_keyboard.t,
	wl_pointer:      wl_pointer.t,
	pointer:         Pointer,
	wl_shm:          wl_shm.t,
	wl_shm_pool:     wl_shm_pool.t,
	wl_buffer:       wl_buffer.t,
	buffer_ready:    bool,
	xdg_wm_base:     xdg_wm_base.t,
	xdg_surface:     xdg_surface.t,
	wl_compositor:   wl_compositor.t,
	wl_surface:      wl_surface.t,
	wl_output:       [constants.MAX_OUTPUTS]Output,
	wl_output_count: int,
	xdg_toplevel:    xdg_toplevel.t,
	stride:          u32,
	max_stride:      u32,
	w:               u32,
	max_w:           u32,
	h:               u32,
	max_h:           u32,
	buf_w:           u32,
	buf_h:           u32,
	shm_pool_size:   u32,
	shm_fd:          linux.Fd,
	shm_pool_data:   ^u8,
	state:           state_state_t,
	event_handlers:  [dynamic]RegisteredEventHandler,
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
	state: ^state_t,
	object_id: u32,
	event_handlers: rawptr,
	handle_event: HandleEventProc,
	user_data: rawptr = nil,
) {
	append(
		&state.event_handlers,
		RegisteredEventHandler {
			event_handlers = event_handlers,
			object_id = object_id,
			handle_event = handle_event,
			user_data = user_data if user_data != nil else state,
		},
	)
}

unregister_event_handler :: proc(state: ^state_t, object_id: u32) {
	for handler, i in state.event_handlers {
		if handler.object_id == object_id {
			if handler.user_data != rawptr(state) {
				free(handler.user_data)
			}
			unordered_remove(&state.event_handlers, i)
			return
		}
	}
}

cleanup :: proc(state: ^state_t) {
	for len(state.event_handlers) > 0 {
		unregister_event_handler(state, state.event_handlers[0].object_id)
	}
	delete(state.event_handlers)
	if state.shm_pool_data != nil do cleanup_shared_memory_file(state)
	wayland_display_connection_cleanup(state.wl_display.socket)
}

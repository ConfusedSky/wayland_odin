package Main

import constants "./constants"
import "core:sys/linux"

state_state_t :: enum {
	STATE_NONE,
	STATE_SURFACE_ACKED_CONFIGURE,
	STATE_SURFACE_ATTACHED,
}

state_t :: struct {
	socket_fd:          linux.Fd,
	wl_registry:        u32,
	wl_shm:             u32,
	wl_shm_pool:        u32,
	wl_buffer:          u32,
	buffer_ready:       bool,
	xdg_wm_base:        u32,
	xdg_surface:        u32,
	wl_compositor:      u32,
	wl_surface:         u32,
	wl_output:          [constants.MAX_OUTPUTS]Output,
	wl_output_count:    int,
	xdg_toplevel:       u32,
	stride:             u32,
	max_stride:         u32,
	w:                  u32,
	max_w:              u32,
	h:                  u32,
	max_h:              u32,
	buf_w:              u32,
	buf_h:              u32,
	shm_pool_size:      u32,
	shm_fd:             linux.Fd,
	shm_pool_data:      ^u8,
	state:              state_state_t,
	wayland_current_id: u32,
	event_handlers:     [dynamic]RegisteredEventHandler,
}

HandleEventProc :: proc(
	object_id: u32,
	opcode: u16,
	msg: ^^u8,
	msg_len: ^int,
	handlers_raw: rawptr,
	user_data: rawptr,
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
			object_id      = object_id,
			handle_event   = handle_event,
			user_data      = user_data if user_data != nil else state,
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
	wayland_display_connection_cleanup(state.socket_fd)
}

package Main

import constants "./constants"
import renderer "./renderer"
import "core:sys/linux"
import wl_buffer "wayland_protocol/wl_buffer"
import wl_compositor "wayland_protocol/wl_compositor"
import wl_display "wayland_protocol/wl_display"
import wl_keyboard "wayland_protocol/wl_keyboard"
import wl_pointer "wayland_protocol/wl_pointer"
import wl_registry "wayland_protocol/wl_registry"
import wl_seat "wayland_protocol/wl_seat"
import wl_shm "wayland_protocol/wl_shm"
import wl_surface "wayland_protocol/wl_surface"
import xdg_surface "wayland_protocol/xdg_surface"
import xdg_toplevel "wayland_protocol/xdg_toplevel"
import xdg_wm_base "wayland_protocol/xdg_wm_base"
import zwp_linux_dmabuf_v1 "wayland_protocol/zwp_linux_dmabuf_v1"

state_state_t :: enum {
	STATE_NONE,
	STATE_SURFACE_ACKED_CONFIGURE,
	STATE_SURFACE_ATTACHED,
}

Errno :: linux.Errno

state_t :: struct {
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
	wl_output:        [constants.MAX_OUTPUTS]Output,
	wl_output_count:  int,
	xdg_toplevel:     xdg_toplevel.t,
	w:                u32,
	max_w:            u32,
	h:                u32,
	max_h:            u32,
	buf_w:            u32,
	buf_h:            u32,
	vk_buf:           renderer.VulkanFrameBuffer,
	state:            state_state_t,
	event_handlers:   [dynamic]RegisteredEventHandler,
	last_err:         Errno,
	vulkan:           renderer.VulkanState,
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
	// IDs are monotonically increasing, so append maintains sorted order
	assert(
		len(state.event_handlers) == 0 ||
		object_id > state.event_handlers[len(state.event_handlers) - 1].object_id,
	)
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
	idx, found := find_event_handler(state.event_handlers[:], object_id)
	if !found do return
	handler := state.event_handlers[idx]
	if handler.user_data != rawptr(state) {
		free(handler.user_data)
	}
	ordered_remove(&state.event_handlers, idx)
}

// Binary search over the sorted event_handlers array.
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

cleanup :: proc(state: ^state_t) -> Errno {
	renderer.free_vulkan_buffer(&state.vulkan, &state.vk_buf)
	renderer.cleanup_vulkan(&state.vulkan)
	for len(state.event_handlers) > 0 {
		unregister_event_handler(state, state.event_handlers[0].object_id)
	}
	delete(state.event_handlers)
	if state.cursor.initialized do cleanup_cursor(&state.cursor) or_return
	wayland_display_connection_cleanup(state.wl_display.socket) or_return
	return nil
}

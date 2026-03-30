package Main

import constants "./constants"
import wl_output "wayland_protocol/wl_output"

Output :: struct {
	object_id: u32,
	is_done:   bool,
	w:         u32,
	h:         u32,
}

OutputUserData :: struct {
	output: ^Output,
	state:  ^state_t,
}

initialize_wl_output :: proc(state: ^state_t, name: u32, version: u32) {
	state.wayland_current_id += 1
	output := Output {
		object_id = registry_bind(
			state.socket_fd,
			state.wl_registry,
			name,
			"wl_output",
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
}

wl_output_handlers := wl_output.EventHandlers {
	on_mode = proc(
		source_object_id: u32,
		flags: wl_output.Mode,
		width: i32,
		height: i32,
		refresh: i32,
		user_data: rawptr,
	) {
		data := (^OutputUserData)(user_data)
		if .Current in flags {
			assert(data.output != nil)
			data.output.w = u32(width)
			data.output.h = u32(height)
		}
	},
	on_done = proc(source_object_id: u32, user_data: rawptr) {
		data := (^OutputUserData)(user_data)
		assert(data.output != nil)
		data.output.is_done = true

		all_done := true
		max_w, max_h: u32
		for &output in data.state.wl_output[:data.state.wl_output_count] {
			if !output.is_done {
				all_done = false
				break
			} else {
				max_w = max(max_w, output.w)
				max_h = max(max_h, output.h)
			}
		}

		if all_done {
			data.state.max_w = max_w
			data.state.max_h = max_h
			data.state.max_stride = data.state.max_w * constants.COLOR_CHANNELS
			data.state.shm_pool_size = data.state.max_h * data.state.max_stride
		}
	},
}

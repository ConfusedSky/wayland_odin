package wayland

import constants "../../constants"
import wl_output "../../wayland_protocol/wl_output"

Output :: struct {
	proxy:   wl_output.t,
	is_done: bool,
	width:   u32,
	height:  u32,
}

OutputUserData :: struct {
	output: ^Output,
	client: ^Client,
}

initialize_wl_output :: proc(client: ^Client, name: u32, version: u32) -> Errno {
	proxy := wl_output.from_global(&client.wl_registry, name, version) or_return
	output := Output {
		proxy   = proxy,
		is_done = false,
	}
	assert(client.output_count < constants.MAX_OUTPUTS)
	client.outputs[client.output_count] = output
	client.output_count += 1
	output_user_data := new(OutputUserData)
	output_user_data^ = OutputUserData {
		client = client,
		output = &client.outputs[client.output_count - 1],
	}
	register_event_handler(
		client,
		proxy.id,
		&wl_output_handlers,
		wl_output.handle_event,
		output_user_data,
	)
	return nil
}

wl_output_handlers := wl_output.EventHandlers {
	on_mode = proc(
		source_object_id: u32,
		flags: wl_output.Mode,
		width: i32,
		height: i32,
		refresh: i32,
		user_data: rawptr,
	) -> Errno {
		data := (^OutputUserData)(user_data)
		if .Current in flags {
			assert(data.output != nil)
			data.output.width = u32(width)
			data.output.height = u32(height)
		}
		return nil
	},
	on_done = proc(source_object_id: u32, user_data: rawptr) -> Errno {
		data := (^OutputUserData)(user_data)
		assert(data.output != nil)
		data.output.is_done = true

		all_done := true
		max_width, max_height: u32
		for &output in data.client.outputs[:data.client.output_count] {
			if !output.is_done {
				all_done = false
				break
			} else {
				max_width = max(max_width, output.width)
				max_height = max(max_height, output.height)
			}
		}

		if all_done {
			data.client.max_width = max_width
			data.client.max_height = max_height
		}
		return nil
	},
}

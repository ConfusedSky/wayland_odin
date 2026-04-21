package app

import constants "../constants"
import platform "../platform"
import renderer "../renderer"
import "core:fmt"
import "core:math"
import "core:sys/linux"

initialize :: proc(state: ^State, max_width: u32, max_height: u32) -> linux.Errno {
	renderer.initialize_vulkan(&state.vulkan) or_return
	renderer.initialize_grid_pipeline(&state.vulkan) or_return
	renderer.initialize_vulkan_commands(&state.vulkan) or_return
	renderer.initialize_shape_renderer(&state.vulkan) or_return
	renderer.initialize_text_renderer(&state.vulkan) or_return

	font, font_err := renderer.load_font(&state.vulkan)
	if font_err != nil do return font_err
	state.font = font

	frame_buf, err := renderer.allocate_vulkan_buffer(&state.vulkan, max_width, max_height)
	if err != nil do return err
	state.frame_buf = frame_buf
	state.initialized = true
	return nil
}

shutdown :: proc(state: ^State) {
	if state.font != nil {
		renderer.destroy_font(&state.vulkan, state.font)
		state.font = nil
	}
	if state.frame_buf.memory != 0 {
		renderer.free_vulkan_buffer(&state.vulkan, &state.frame_buf)
	}
	renderer.cleanup_vulkan(&state.vulkan)
	state.initialized = false
}

render_frame :: proc(
	state: ^State,
	info: platform.Frame_Info,
) -> (
	rendered: bool,
	err: linux.Errno,
) {
	assert(state.frame_buf.memory != 0)
	assert(info.width > 0 && info.height > 0)

	fmt.printfln("Drawing next frame")

	if info.width < constants.NUM_CELLS || info.height < constants.NUM_CELLS {
		fmt.eprintfln("State is too small to safely draw the next frame")
		return false, nil
	}

	renderer.start_shapes(&state.vulkan)
	renderer.start_text(&state.vulkan)

	renderer.draw_shape(
		&state.vulkan,
		{
			data = renderer.LineData{p0 = {100, 100}, p1 = {400, 200}, width = 16, cap = .Round},
			style = {fill_color = {1, 0.2, 0.2, 1}, border_color = {1, 1, 1, 1}, border_width = 4},
		},
	)
	renderer.draw_shape(
		&state.vulkan,
		{
			data = renderer.LineData{p0 = {100, 160}, p1 = {400, 260}, width = 24, cap = .Square},
			style = {
				fill_color = {0.2, 0.5, 1, 0.8},
				border_color = {1, 1, 1, 1},
				border_width = 4,
			},
		},
	)

	renderer.draw_shape(
		&state.vulkan,
		{
			data = renderer.RectData{pos = {120, 280}, size = {160, 80}},
			style = {
				fill_color = {0.3, 0.8, 0.3, 1},
				border_color = {1, 1, 0, 1},
				border_width = 4,
			},
		},
	)
	renderer.draw_shape(
		&state.vulkan,
		{
			data = renderer.RectData{pos = {280, 260}, size = {120, 120}},
			transform = {angle = math.PI / 4, zindex = 1},
			style = {
				fill_color = {0.8, 0.3, 0.8, 0.5},
				border_color = {1, 1, 1, 1},
				border_width = 4,
			},
		},
	)

	renderer.draw_shape(
		&state.vulkan,
		{
			data = renderer.RoundedRectData{pos = {90, 395}, size = {140, 70}, corner_radius = 12},
			style = {fill_color = {1, 0.6, 0.1, 1}, border_color = {1, 1, 1, 1}, border_width = 4},
		},
	)
	renderer.draw_shape(
		&state.vulkan,
		{
			data = renderer.RoundedRectData {
				pos = {230, 390},
				size = {160, 80},
				corner_radius = 20,
			},
			style = {
				fill_color = {0.1, 0.8, 0.9, 0.7},
				border_color = {1, 1, 1, 1},
				border_width = 4,
			},
		},
	)

	renderer.draw_shape(
		&state.vulkan,
		{
			data = renderer.TriangleData{p0 = {510, 110}, p1 = {590, 260}, p2 = {430, 260}},
			style = {fill_color = {1, 0.4, 0, 1}, border_color = {1, 1, 1, 1}, border_width = 4},
		},
	)
	renderer.draw_shape(
		&state.vulkan,
		{
			data = renderer.TriangleData{p0 = {510, 290}, p1 = {570, 390}, p2 = {450, 390}},
			style = {fill_color = {0.5, 0, 1, 0.8}, border_color = {1, 1, 1, 1}, border_width = 4},
		},
	)

	renderer.draw_shape(
		&state.vulkan,
		{
			data = renderer.OvalData{center = {210, 530}, radii = {90, 40}},
			style = {fill_color = {1, 0.2, 0.5, 1}, border_color = {1, 1, 1, 1}, border_width = 4},
		},
	)
	renderer.draw_shape(
		&state.vulkan,
		{
			data = renderer.OvalData{center = {390, 530}, radii = {40, 70}},
			style = {
				fill_color = {0.2, 0.9, 0.4, 0.6},
				border_color = {1, 1, 1, 1},
				border_width = 4,
			},
		},
	)

	renderer.draw_shape(
		&state.vulkan,
		{
			data = renderer.CircleData{center = {530, 430}, radius = 45},
			style = {fill_color = {1, 1, 1, 1}},
		},
	)
	renderer.draw_shape(
		&state.vulkan,
		{
			data = renderer.CircleData{center = {640, 430}, radius = 30},
			style = {fill_color = {0, 0.6, 1, 0.7}, border_color = {1, 1, 1, 1}, border_width = 4},
		},
	)

	text := renderer.TextData {
		text = "Hello, World!",
		pos = {f32(info.width), 0},
		style = {font = state.font, color = {1, 1, 1, 1}},
		anchor = .TopLeft,
	}
	rect := renderer.get_bounding_box(text)
	text.pos.x -= rect.size.x
	fmt.println(rect)
	shape := renderer.ShapeData {
		data = renderer.RectData{pos = rect.pos - {rect.size.x, 0}, size = rect.size},
		style = {fill_color = {1, 0, 0, 0.7}},
	}

	renderer.draw(&state.vulkan, text)
	renderer.draw(&state.vulkan, shape)

	err = renderer.render_frame(
		&state.vulkan,
		&state.frame_buf,
		renderer.RenderParams {
			width = info.width,
			height = info.height,
			pointer_x = f32(info.pointer_x),
			pointer_y = f32(info.pointer_y),
		},
	)
	if err != nil do return false, err

	return true, nil
}

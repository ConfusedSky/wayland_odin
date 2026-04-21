package app

import constants "../constants"
import platform "../platform"
import renderer "../renderer"
import runtime_log "../runtime_log"
import "core:fmt"
import "core:math"
import "core:sys/linux"

initialize :: proc(
	state: ^State,
	log_blacklist: []string,
	max_width: u32,
	max_height: u32,
) -> linux.Errno {
	runtime_log.initialize(&state.logger, log_blacklist)
	renderer.initialize_vulkan(&state.vulkan, &state.logger) or_return
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
	state.objects = make([dynamic]SceneObject)
	initialize_scene(state)
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
	delete(state.objects)
	runtime_log.cleanup(&state.logger)
	renderer.cleanup_vulkan(&state.vulkan)
	state.initialized = false
}

render_frame :: proc(
	state: ^State,
	info: platform.FrameInfo,
) -> (
	rendered: bool,
	err: linux.Errno,
) {
	assert(state.frame_buf.memory != 0)
	assert(info.width > 0 && info.height > 0)

	if runtime_log.should_log(&state.logger, "app.frame.draw") {
		fmt.printfln("Drawing next frame")
	}

	if info.width < constants.NUM_CELLS || info.height < constants.NUM_CELLS {
		fmt.eprintfln("State is too small to safely draw the next frame")
		return false, nil
	}

	update_drag(state, info)
	layout_scene(state, info)

	renderer.start_shapes(&state.vulkan)
	renderer.start_text(&state.vulkan)

	for object in state.objects {
		renderer.draw(&state.vulkan, object.renderable)
	}

	err = renderer.render_frame(
		&state.vulkan,
		&state.frame_buf,
		renderer.RenderParams {
			width = info.width,
			height = info.height,
			pointer_x = f32(info.pointer.x),
			pointer_y = f32(info.pointer.y),
		},
	)
	if err != nil do return false, err

	return true, nil
}

initialize_scene :: proc(state: ^State) {
	add_scene_object(
		state,
		renderer.ShapeData {
			data = renderer.LineData{p0 = {100, 100}, p1 = {400, 200}, width = 16, cap = .Round},
			style = {fill_color = {1, 0.2, 0.2, 1}, border_color = {1, 1, 1, 1}, border_width = 4},
		},
		true,
	)
	add_scene_object(
		state,
		renderer.ShapeData {
			data = renderer.LineData{p0 = {100, 160}, p1 = {400, 260}, width = 24, cap = .Square},
			style = {
				fill_color = {0.2, 0.5, 1, 0.8},
				border_color = {1, 1, 1, 1},
				border_width = 4,
			},
		},
		true,
	)
	add_scene_object(
		state,
		renderer.ShapeData {
			data = renderer.RectData{pos = {120, 280}, size = {160, 80}},
			style = {
				fill_color = {0.3, 0.8, 0.3, 1},
				border_color = {1, 1, 0, 1},
				border_width = 4,
			},
		},
		true,
	)
	add_scene_object(
		state,
		renderer.ShapeData {
			data = renderer.RectData{pos = {280, 260}, size = {120, 120}},
			transform = {angle = math.PI / 4, zindex = 1},
			style = {
				fill_color = {0.8, 0.3, 0.8, 0.5},
				border_color = {1, 1, 1, 1},
				border_width = 4,
			},
		},
		true,
	)
	add_scene_object(
		state,
		renderer.ShapeData {
			data = renderer.RoundedRectData{pos = {90, 395}, size = {140, 70}, corner_radius = 12},
			style = {fill_color = {1, 0.6, 0.1, 1}, border_color = {1, 1, 1, 1}, border_width = 4},
		},
		true,
	)
	add_scene_object(
		state,
		renderer.ShapeData {
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
		true,
	)
	add_scene_object(
		state,
		renderer.ShapeData {
			data = renderer.TriangleData{p0 = {510, 110}, p1 = {590, 260}, p2 = {430, 260}},
			style = {fill_color = {1, 0.4, 0, 1}, border_color = {1, 1, 1, 1}, border_width = 4},
		},
		true,
	)
	add_scene_object(
		state,
		renderer.ShapeData {
			data = renderer.TriangleData{p0 = {510, 290}, p1 = {570, 390}, p2 = {450, 390}},
			style = {fill_color = {0.5, 0, 1, 0.8}, border_color = {1, 1, 1, 1}, border_width = 4},
		},
		true,
	)
	add_scene_object(
		state,
		renderer.ShapeData {
			data = renderer.OvalData{center = {210, 530}, radii = {90, 40}},
			style = {fill_color = {1, 0.2, 0.5, 1}, border_color = {1, 1, 1, 1}, border_width = 4},
		},
		true,
	)
	add_scene_object(
		state,
		renderer.ShapeData {
			data = renderer.OvalData{center = {390, 530}, radii = {40, 70}},
			style = {
				fill_color = {0.2, 0.9, 0.4, 0.6},
				border_color = {1, 1, 1, 1},
				border_width = 4,
			},
		},
		true,
	)
	add_scene_object(
		state,
		renderer.ShapeData {
			data = renderer.CircleData{center = {530, 430}, radius = 45},
			style = {fill_color = {1, 1, 1, 1}},
		},
		true,
	)
	add_scene_object(
		state,
		renderer.ShapeData {
			data = renderer.CircleData{center = {640, 430}, radius = 30},
			style = {fill_color = {0, 0.6, 1, 0.7}, border_color = {1, 1, 1, 1}, border_width = 4},
		},
		true,
	)
	// layout_hello_world_text must be added before layout_hello_world_background
	// since the background's layout reads the text object's current renderable.
	add_scene_object(
		state,
		renderer.TextData {
			text = "Hello, World!",
			style = {font = state.font, color = {1, 1, 1, 1}},
			anchor = .TopLeft,
		},
		false,
		layout_hello_world_text,
	)
	add_scene_object(
		state,
		renderer.ShapeData{data = renderer.RectData{}, style = {fill_color = {1, 0, 0, 0.7}}},
		false,
		layout_hello_world_background,
	)
}

layout_hello_world_text :: proc(object: ^SceneObject, state: ^State, info: platform.FrameInfo) {
	text := object_renderable_text(object)
	text.pos = {f32(info.width), 0}
	text.style.font = state.font
	bounds := renderer.get_bounding_box(text)
	text.pos.x -= bounds.size.x
	object.renderable = text
}

layout_hello_world_background :: proc(object: ^SceneObject, state: ^State, _: platform.FrameInfo) {
	for other in state.objects {
		if other.layout_proc == layout_hello_world_text {
			text_bounds := renderer.get_bounding_box(other.renderable)
			object.renderable = renderer.ShapeData {
				data = renderer.RectData{pos = text_bounds.pos, size = text_bounds.size},
				style = {fill_color = {1, 0, 0, 0.7}},
			}
			return
		}
	}
}

add_scene_object :: proc(
	state: ^State,
	renderable: renderer.Renderable,
	movable: bool,
	layout_proc: LayoutProc = nil,
) {
	object := SceneObject {
		id          = state.next_id,
		layout_proc = layout_proc,
		renderable  = renderable,
		movable     = movable,
		bounds      = renderer.get_bounding_box(renderable),
	}
	append(&state.objects, object)
	state.next_id += 1
}

layout_scene :: proc(state: ^State, info: platform.FrameInfo) {
	for i in 0 ..< len(state.objects) {
		object := &state.objects[i]
		if object.layout_proc != nil {
			object.layout_proc(object, state, info)
			object.bounds = renderer.get_bounding_box(object.renderable)
		}
	}
}

update_drag :: proc(state: ^State, info: platform.FrameInfo) {
	pointer := [2]f32{f32(info.pointer.x), f32(info.pointer.y)}

	if info.pointer.left_button_pressed {
		idx, found := hit_test(state, pointer)
		if found {
			object := &state.objects[idx]
			state.drag.dragging = true
			state.drag.active_object_id = object.id
			state.drag.grab_offset = pointer - object.bounds.pos
		}
	}

	if state.drag.dragging && info.pointer.left_button_down {
		idx, found := find_object_index_by_id(state, state.drag.active_object_id)
		if found {
			object := &state.objects[idx]
			target_pos := pointer - state.drag.grab_offset
			delta := target_pos - object.bounds.pos
			translate_renderable(&object.renderable, delta)
			object.bounds = renderer.get_bounding_box(object.renderable)
		}
	}

	if info.pointer.left_button_released {
		state.drag = {}
	}
}

hit_test :: proc(state: ^State, point: [2]f32) -> (int, bool) {
	for i := len(state.objects) - 1; i >= 0; i -= 1 {
		object := state.objects[i]
		if !object.movable do continue
		if point_in_rect(point, object.bounds) {
			return i, true
		}
	}
	return 0, false
}

point_in_rect :: proc(point: [2]f32, rect: renderer.Rect) -> bool {
	return(
		point.x >= rect.pos.x &&
		point.y >= rect.pos.y &&
		point.x <= rect.pos.x + rect.size.x &&
		point.y <= rect.pos.y + rect.size.y \
	)
}

find_object_index_by_id :: proc(state: ^State, id: int) -> (int, bool) {
	for i in 0 ..< len(state.objects) {
		if state.objects[i].id == id {
			return i, true
		}
	}
	return 0, false
}

object_renderable_text :: proc(object: ^SceneObject) -> renderer.TextData {
	#partial switch value in object.renderable {
	case renderer.TextData:
		return value
	}
	panic("scene object is not text")
}

translate_renderable :: proc(renderable: ^renderer.Renderable, delta: [2]f32) {
	switch value in renderable^ {
	case renderer.ShapeData:
		shape := value
		translate_shape(&shape, delta)
		renderable^ = shape
	case renderer.TextData:
		text := value
		text.pos += delta
		renderable^ = text
	}
}

translate_shape :: proc(shape: ^renderer.ShapeData, delta: [2]f32) {
	switch data in shape.data {
	case renderer.LineData:
		line := data
		line.p0 += delta
		line.p1 += delta
		shape.data = line
	case renderer.RectData:
		rect := data
		rect.pos += delta
		shape.data = rect
	case renderer.RoundedRectData:
		rect := data
		rect.pos += delta
		shape.data = rect
	case renderer.TriangleData:
		triangle := data
		triangle.p0 += delta
		triangle.p1 += delta
		triangle.p2 += delta
		shape.data = triangle
	case renderer.OvalData:
		oval := data
		oval.center += delta
		shape.data = oval
	case renderer.CircleData:
		circle := data
		circle.center += delta
		shape.data = circle
	}
}

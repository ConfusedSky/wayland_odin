package app

import platform "../platform"
import renderer "../renderer"
import runtime_log "../runtime_log"

Layout_Proc :: proc(object: ^Scene_Object, state: ^State, info: platform.FrameInfo)

Scene_Object :: struct {
	id:          int,
	layout_proc: Layout_Proc,
	renderable:  renderer.Renderable,
	movable:     bool,
	bounds:      renderer.Rect,
}

Drag_State :: struct {
	active_object_id: int,
	grab_offset:      [2]f32,
	dragging:         bool,
}

State :: struct {
	vulkan:      renderer.VulkanState,
	frame_buf:   renderer.VulkanFrameBuffer,
	font:        ^renderer.Font,
	logger:      runtime_log.Logger,
	objects:     [dynamic]Scene_Object,
	drag:        Drag_State,
	next_id:     int,
	initialized: bool,
}

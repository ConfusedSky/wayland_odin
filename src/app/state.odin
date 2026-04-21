package app

import renderer "../renderer"
import runtime_log "../runtime_log"

Scene_Object_Kind :: enum {
	Free,
	Hello_World_Background,
	Hello_World_Text,
}

Scene_Object :: struct {
	id:         int,
	kind:       Scene_Object_Kind,
	renderable: renderer.Renderable,
	movable:    bool,
	bounds:     renderer.Rect,
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

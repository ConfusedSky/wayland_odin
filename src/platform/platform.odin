package platform

import renderer "../renderer"
import impl "./wayland"

Errno :: impl.Errno
Init_Params :: impl.Init_Params

Pointer :: struct {
	x:                    f64,
	y:                    f64,
	left_button_down:     bool,
	left_button_pressed:  bool,
	left_button_released: bool,
}

Frame_Info :: struct {
	width:   u32,
	height:  u32,
	pointer: Pointer,
}

Context :: struct {
	impl: impl.Client,
}

init :: proc(ctx: ^Context, params: Init_Params) -> Errno {
	return impl.init(&ctx.impl, params)
}

pump :: proc(ctx: ^Context) -> Errno {
	return impl.pump(&ctx.impl)
}

should_close :: proc(ctx: ^Context) -> bool {
	return impl.should_close(&ctx.impl)
}

ready_for_frame :: proc(ctx: ^Context) -> bool {
	return impl.ready_for_frame(&ctx.impl)
}

frame_info :: proc(ctx: ^Context) -> Frame_Info {
	info := impl.frame_info(&ctx.impl)
	return Frame_Info {
		width = info.width,
		height = info.height,
		pointer = Pointer {
			x = info.pointer.x,
			y = info.pointer.y,
			left_button_down = info.pointer.left_button_down,
			left_button_pressed = info.pointer.left_button_pressed,
			left_button_released = info.pointer.left_button_released,
		},
	}
}

max_surface_size :: proc(ctx: ^Context) -> (u32, u32) {
	return impl.max_surface_size(&ctx.impl)
}

present_dmabuf :: proc(ctx: ^Context, buf: ^renderer.VulkanFrameBuffer) -> Errno {
	return impl.present_dmabuf(&ctx.impl, buf)
}

skip_frame :: proc(ctx: ^Context) {
	impl.skip_frame(&ctx.impl)
}

shutdown :: proc(ctx: ^Context) -> Errno {
	return impl.shutdown(&ctx.impl)
}

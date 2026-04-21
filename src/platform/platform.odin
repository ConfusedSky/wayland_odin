package platform

import renderer "../renderer"
import impl "./wayland"

Errno :: impl.Errno
Init_Params :: impl.Init_Params
Frame_Info :: impl.Frame_Info

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
	return impl.frame_info(&ctx.impl)
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

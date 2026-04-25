package platform

import ptypes "../platform_types"
import renderer "../renderer"
import impl "./wayland"
import "core:sys/linux"

Errno :: linux.Errno

InitParams :: ptypes.InitParams
Pointer :: ptypes.Pointer
FrameInfo :: ptypes.FrameInfo

Context :: struct {
	impl: impl.Client,
}

init :: proc(ctx: ^Context, params: InitParams) -> Errno {
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

consume_frame_info :: proc(ctx: ^Context) -> FrameInfo {
	return impl.consume_frame_info(&ctx.impl)
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

request_frame :: proc(ctx: ^Context) {
	impl.request_frame(&ctx.impl)
}

pending_update :: proc(ctx: ^Context) -> bool {
	return impl.pending_update(&ctx.impl)
}

surface_size :: proc(ctx: ^Context) -> (u32, u32) {
	return impl.surface_size(&ctx.impl)
}

shutdown :: proc(ctx: ^Context) -> Errno {
	return impl.shutdown(&ctx.impl)
}

package renderer

import runtime_log "../runtime_log"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:slice"
import "core:sys/linux"
import stbtt "vendor:stb/truetype"
import vk "vendor:vulkan"

FONT_PATH :: "/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf"
FONT_OVERSAMPLE_H :: u32(4)
FONT_OVERSAMPLE_V :: u32(4)
ATLAS_SIZE_TOLERANCE :: f32(5)

GLYPH_FIRST :: 32
GLYPH_COUNT :: 96

GlyphInfo :: struct {
	uv_min:  [2]f32,
	uv_max:  [2]f32,
	offset:  [2]f32, // bearing: pen-to-glyph-top-left in pixels
	size:    [2]f32, // bitmap size in pixels
	advance: f32,
}

Font :: struct {
	pixel_size:       f32,
	ascent, descent:  f32,
	glyphs:           [GLYPH_COUNT]GlyphInfo,
	atlas_w, atlas_h: u32,
	atlas_image:      vk.Image,
	atlas_memory:     vk.DeviceMemory,
	atlas_view:       vk.ImageView,
	atlas_sampler:    vk.Sampler,
	descriptor_set:   vk.DescriptorSet,
	vertex_buf:       VulkanBuffer(.VERTEX_BUFFER, TextVertex),
}

TextAnchor :: enum int {
	Baseline,
	TopLeft,
}

TextStyle :: struct {
	color: [4]f32,
	size:  f32,
}

TextData :: struct {
	text:   string,
	pos:    [2]f32,
	style:  TextStyle,
	anchor: TextAnchor,
	zindex: f32,
}

TextVertex :: struct #packed {
	pos:   [2]f32,
	uv:    [2]f32,
	color: [4]f32,
}

TextDraw :: struct {
	text:   string,
	pos:    [2]f32,
	style:  TextStyle,
	zindex: f32,
}

TextRenderer :: struct {
	atlases:      [dynamic]^Font,
	text_draws:   [dynamic]TextDraw,
	vertices:     [dynamic]TextVertex,
	pool:         vk.DescriptorPool,
	pipeline:     VulkanPipeline(2, TextVertex),
	default_size: f32,
}

// ---------------------------------------------------------------------------
// Atlas size calculation
// ---------------------------------------------------------------------------

@(private)
next_pow2 :: proc(v: u32) -> u32 {
	n := v - 1
	n |= n >> 1
	n |= n >> 2
	n |= n >> 4
	n |= n >> 8
	n |= n >> 16
	return n + 1
}

// Returns the smallest square power-of-2 atlas that can fit all glyphs.
// Assumes ~75% packing efficiency from stb_truetype's bin packer.
@(private)
compute_atlas_size :: proc(pixel_size: f32, oversample_h, oversample_v: u32) -> (w, h: u32) {
	glyph_w := u32(pixel_size * f32(oversample_h)) + 2
	glyph_h := u32(pixel_size * f32(oversample_v)) + 2
	total_area := u32(GLYPH_COUNT) * glyph_w * glyph_h
	// 4/3 factor accounts for packing inefficiency
	padded := total_area * 4 / 3
	side := next_pow2(u32(math.sqrt(f32(padded))) + 1)
	return side, side
}

// ---------------------------------------------------------------------------
// Initialization / teardown
// ---------------------------------------------------------------------------

initialize_text_renderer :: proc(state: ^VulkanState) -> (err: linux.Errno) {
	t := &state.text_renderer
	t.atlases = make([dynamic]^Font)
	t.text_draws = make([dynamic]TextDraw)
	t.vertices = make([dynamic]TextVertex)
	t.default_size = 16

	pool_size := vk.DescriptorPoolSize {
		type            = .COMBINED_IMAGE_SAMPLER,
		descriptorCount = 32,
	}
	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets       = 32,
		poolSizeCount = 1,
		pPoolSizes    = &pool_size,
	}
	if res := vk.CreateDescriptorPool(state.device, &pool_info, nil, &t.pool); res != .SUCCESS {
		fmt.eprintln("text: vkCreateDescriptorPool failed:", res)
		return .EINVAL
	}

	descriptor_bindings := []vk.DescriptorSetLayoutBinding {
		{
			binding = 0,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		},
	}
	info := VulkanPipelineInfo {
		vertex_spv          = #load("shaders/text.vert.spv"),
		fragment_spv        = #load("shaders/text.frag.spv"),
		descriptor_bindings = descriptor_bindings,
	}
	initialize_rendering_pipeline(state, &t.pipeline, &info) or_return

	if runtime_log.should_log(state.logger, "renderer.text.renderer_initialized") {
		fmt.printfln("text: renderer initialized")
	}
	return nil
}

destroy_text_renderer :: proc(state: ^VulkanState) {
	t := &state.text_renderer
	for font in t.atlases {
		destroy_font(state, font)
	}
	delete(t.atlases)
	destroy_pipeline(state, &t.pipeline)
	if t.pool != 0 {
		vk.DestroyDescriptorPool(state.device, t.pool, nil)
		t.pool = 0
	}
	delete(t.text_draws)
	delete(t.vertices)
}

// acquire_atlas returns the cached atlas whose pixel_size is within
// ATLAS_SIZE_TOLERANCE of size, or loads and caches a new one.
// A non-zero size also sets the default used when size == 0.
acquire_atlas :: proc(state: ^VulkanState, size: f32) -> (font: ^Font, err: linux.Errno) {
	t := &state.text_renderer
	effective := size
	if effective == 0 {
		effective = t.default_size
	} else {
		t.default_size = size
	}
	best: ^Font
	best_diff := max(f32)
	for atlas in t.atlases {
		diff := abs(atlas.pixel_size - effective)
		if diff < best_diff {
			best_diff = diff
			best = atlas
		}
	}
	if best_diff <= ATLAS_SIZE_TOLERANCE do return best, nil
	return load_font(state, effective)
}

load_font :: proc(state: ^VulkanState, pixel_size: f32) -> (font: ^Font, err: linux.Errno) {
	font = new(Font)
	defer if err != nil {
		destroy_font(state, font)
		font = nil
	}

	font_data, os_err := os.read_entire_file_from_path(FONT_PATH, context.allocator)
	if os_err != nil {
		fmt.eprintln("text: failed to read font:", FONT_PATH)
		err = .ENOENT
		return
	}
	defer delete(font_data)

	font.pixel_size = pixel_size
	atlas_w, atlas_h := compute_atlas_size(pixel_size, FONT_OVERSAMPLE_H, FONT_OVERSAMPLE_V)
	font.atlas_w = atlas_w
	font.atlas_h = atlas_h

	bitmap := make([]u8, atlas_w * atlas_h)
	defer delete(bitmap)

	chardata: [GLYPH_COUNT]stbtt.packedchar
	spc: stbtt.pack_context
	if stbtt.PackBegin(&spc, raw_data(bitmap), i32(atlas_w), i32(atlas_h), 0, 1, nil) == 0 {
		fmt.eprintln("text: PackBegin failed")
		err = .EINVAL
		return
	}
	stbtt.PackSetOversampling(&spc, FONT_OVERSAMPLE_H, FONT_OVERSAMPLE_V)
	pack_result := stbtt.PackFontRange(
		&spc,
		raw_data(font_data),
		0,
		pixel_size,
		GLYPH_FIRST,
		GLYPH_COUNT,
		&chardata[0],
	)
	stbtt.PackEnd(&spc)
	if pack_result == 0 {
		fmt.eprintln("text: PackFontRange failed — atlas too small for oversampled glyphs")
		err = .EINVAL
		return
	}

	line_gap: f32
	stbtt.GetScaledFontVMetrics(
		raw_data(font_data),
		0,
		pixel_size,
		&font.ascent,
		&font.descent,
		&line_gap,
	)

	for i in 0 ..< GLYPH_COUNT {
		xpos, ypos: f32
		q: stbtt.aligned_quad
		stbtt.GetPackedQuad(
			&chardata[0],
			i32(atlas_w),
			i32(atlas_h),
			i32(i),
			&xpos,
			&ypos,
			&q,
			false,
		)
		font.glyphs[i] = GlyphInfo {
			uv_min  = {q.s0, q.t0},
			uv_max  = {q.s1, q.t1},
			offset  = {q.x0, q.y0},
			size    = {q.x1 - q.x0, q.y1 - q.y0},
			advance = chardata[i].xadvance,
		}
	}

	upload_font_atlas(state, font, bitmap, atlas_w, atlas_h) or_return

	dsl := state.text_renderer.pipeline.descriptor_set_layout
	alloc_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = state.text_renderer.pool,
		descriptorSetCount = 1,
		pSetLayouts        = &dsl,
	}
	if res := vk.AllocateDescriptorSets(state.device, &alloc_info, &font.descriptor_set);
	   res != .SUCCESS {
		fmt.eprintln("text: vkAllocateDescriptorSets failed:", res)
		err = .EINVAL
		return
	}

	image_info := vk.DescriptorImageInfo {
		sampler     = font.atlas_sampler,
		imageView   = font.atlas_view,
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
	}
	write := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = font.descriptor_set,
		dstBinding      = 0,
		descriptorCount = 1,
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		pImageInfo      = &image_info,
	}
	vk.UpdateDescriptorSets(state.device, 1, &write, 0, nil)

	append(&state.text_renderer.atlases, font)

	if runtime_log.should_log(state.logger, "renderer.text.font_loaded") {
		fmt.printfln("text: font loaded (%.0fpx, %dx%d atlas)", pixel_size, atlas_w, atlas_h)
	}
	return
}

destroy_font :: proc(state: ^VulkanState, font: ^Font) {
	if font == nil do return
	font_destroy_buffers(state, font)
	if font.atlas_sampler != 0 {
		vk.DestroySampler(state.device, font.atlas_sampler, nil)
	}
	if font.atlas_view != 0 {
		vk.DestroyImageView(state.device, font.atlas_view, nil)
	}
	if font.atlas_image != 0 {
		vk.DestroyImage(state.device, font.atlas_image, nil)
	}
	if font.atlas_memory != 0 {
		vk.FreeMemory(state.device, font.atlas_memory, nil)
	}
	free(font)
}

// ---------------------------------------------------------------------------
// Per-font vertex / index buffer management
// ---------------------------------------------------------------------------

@(private)
font_ensure_buffers :: proc(state: ^VulkanState, font: ^Font, needed_quads: u32) -> linux.Errno {
	needed_verts := vk.DeviceSize(needed_quads) * 4
	if needed_verts <= font.vertex_buf.capacity do return nil

	new_cap := max(needed_verts * 2, 64)
	new_cap = (new_cap + 3) / 4 * 4

	ensure_buffer_capacity(state, &font.vertex_buf, new_cap) or_return
	ensure_quad_index_buffer(state, &state.quad_index_buf, new_cap / 4) or_return

	return nil
}

@(private)
font_destroy_buffers :: proc(state: ^VulkanState, font: ^Font) {
	destroy_buffer(state, &font.vertex_buf)
}

// ---------------------------------------------------------------------------
// Font atlas GPU upload (unchanged)
// ---------------------------------------------------------------------------

@(private)
upload_font_atlas :: proc(
	state: ^VulkanState,
	font: ^Font,
	bitmap: []u8,
	atlas_w, atlas_h: u32,
) -> (
	err: linux.Errno,
) {
	subresource_range := vk.ImageSubresourceRange {
		aspectMask = {.COLOR},
		levelCount = 1,
		layerCount = 1,
	}

	image_info := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		format = .R8_UNORM,
		extent = {width = atlas_w, height = atlas_h, depth = 1},
		mipLevels = 1,
		arrayLayers = 1,
		samples = {._1},
		tiling = .OPTIMAL,
		usage = {.TRANSFER_DST, .SAMPLED},
		sharingMode = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	if res := vk.CreateImage(state.device, &image_info, nil, &font.atlas_image); res != .SUCCESS {
		fmt.eprintln("text: vkCreateImage failed:", res)
		return .EINVAL
	}

	mem_reqs: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(state.device, font.atlas_image, &mem_reqs)
	mem_type := find_memory_type(
		state.mem_props,
		mem_reqs.memoryTypeBits,
		{.DEVICE_LOCAL},
	) or_return
	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = mem_reqs.size,
		memoryTypeIndex = mem_type,
	}
	if res := vk.AllocateMemory(state.device, &alloc_info, nil, &font.atlas_memory);
	   res != .SUCCESS {
		fmt.eprintln("text: vkAllocateMemory (atlas) failed:", res)
		return .ENOMEM
	}
	vk.BindImageMemory(state.device, font.atlas_image, font.atlas_memory, 0)

	// Staging buffer
	staging_size := vk.DeviceSize(len(bitmap))
	staging_buf: vk.Buffer
	staging_mem: vk.DeviceMemory

	buf_info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = staging_size,
		usage       = {.TRANSFER_SRC},
		sharingMode = .EXCLUSIVE,
	}
	if res := vk.CreateBuffer(state.device, &buf_info, nil, &staging_buf); res != .SUCCESS {
		fmt.eprintln("text: vkCreateBuffer (staging) failed:", res)
		return .EINVAL
	}
	defer vk.DestroyBuffer(state.device, staging_buf, nil)

	vk.GetBufferMemoryRequirements(state.device, staging_buf, &mem_reqs)
	stg_type := find_memory_type(
		state.mem_props,
		mem_reqs.memoryTypeBits,
		{.HOST_VISIBLE, .HOST_COHERENT},
		vk.MemoryPropertyFlags{.HOST_VISIBLE},
	) or_return
	stg_alloc := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = mem_reqs.size,
		memoryTypeIndex = stg_type,
	}
	if res := vk.AllocateMemory(state.device, &stg_alloc, nil, &staging_mem); res != .SUCCESS {
		fmt.eprintln("text: vkAllocateMemory (staging) failed:", res)
		return .ENOMEM
	}
	defer vk.FreeMemory(state.device, staging_mem, nil)
	vk.BindBufferMemory(state.device, staging_buf, staging_mem, 0)

	mapped: rawptr
	vk.MapMemory(state.device, staging_mem, 0, vk.DeviceSize(vk.WHOLE_SIZE), {}, &mapped)
	mem.copy(mapped, raw_data(bitmap), len(bitmap))
	flush_range := vk.MappedMemoryRange {
		sType  = .MAPPED_MEMORY_RANGE,
		memory = staging_mem,
		offset = 0,
		size   = vk.DeviceSize(vk.WHOLE_SIZE),
	}
	vk.FlushMappedMemoryRanges(state.device, 1, &flush_range)
	vk.UnmapMemory(state.device, staging_mem)

	// One-time command buffer for upload
	cmd_alloc := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = state.command_pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}
	cmd: vk.CommandBuffer
	if res := vk.AllocateCommandBuffers(state.device, &cmd_alloc, &cmd); res != .SUCCESS {
		fmt.eprintln("text: vkAllocateCommandBuffers failed:", res)
		return .EINVAL
	}
	defer vk.FreeCommandBuffers(state.device, state.command_pool, 1, &cmd)

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk.BeginCommandBuffer(cmd, &begin_info)

	barrier_to_dst := vk.ImageMemoryBarrier {
		sType               = .IMAGE_MEMORY_BARRIER,
		srcAccessMask       = {},
		dstAccessMask       = {.TRANSFER_WRITE},
		oldLayout           = .UNDEFINED,
		newLayout           = .TRANSFER_DST_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = font.atlas_image,
		subresourceRange    = subresource_range,
	}
	vk.CmdPipelineBarrier(cmd, {.TOP_OF_PIPE}, {.TRANSFER}, {}, 0, nil, 0, nil, 1, &barrier_to_dst)

	copy_region := vk.BufferImageCopy {
		imageSubresource = {aspectMask = {.COLOR}, layerCount = 1},
		imageExtent = {width = atlas_w, height = atlas_h, depth = 1},
	}
	vk.CmdCopyBufferToImage(
		cmd,
		staging_buf,
		font.atlas_image,
		.TRANSFER_DST_OPTIMAL,
		1,
		&copy_region,
	)

	barrier_to_read := vk.ImageMemoryBarrier {
		sType               = .IMAGE_MEMORY_BARRIER,
		srcAccessMask       = {.TRANSFER_WRITE},
		dstAccessMask       = {.SHADER_READ},
		oldLayout           = .TRANSFER_DST_OPTIMAL,
		newLayout           = .SHADER_READ_ONLY_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = font.atlas_image,
		subresourceRange    = subresource_range,
	}
	vk.CmdPipelineBarrier(
		cmd,
		{.TRANSFER},
		{.FRAGMENT_SHADER},
		{},
		0,
		nil,
		0,
		nil,
		1,
		&barrier_to_read,
	)

	vk.EndCommandBuffer(cmd)

	submit := vk.SubmitInfo {
		sType              = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = &cmd,
	}
	vk.QueueSubmit(state.graphics_queue, 1, &submit, 0)
	vk.QueueWaitIdle(state.graphics_queue)

	view_info := vk.ImageViewCreateInfo {
		sType            = .IMAGE_VIEW_CREATE_INFO,
		image            = font.atlas_image,
		viewType         = .D2,
		format           = .R8_UNORM,
		subresourceRange = subresource_range,
	}
	if res := vk.CreateImageView(state.device, &view_info, nil, &font.atlas_view);
	   res != .SUCCESS {
		fmt.eprintln("text: vkCreateImageView failed:", res)
		return .EINVAL
	}

	sampler_info := vk.SamplerCreateInfo {
		sType        = .SAMPLER_CREATE_INFO,
		magFilter    = .LINEAR,
		minFilter    = .LINEAR,
		addressModeU = .CLAMP_TO_EDGE,
		addressModeV = .CLAMP_TO_EDGE,
	}
	if res := vk.CreateSampler(state.device, &sampler_info, nil, &font.atlas_sampler);
	   res != .SUCCESS {
		fmt.eprintln("text: vkCreateSampler failed:", res)
		return .EINVAL
	}

	return nil
}

// ---------------------------------------------------------------------------
// Per-frame API
// ---------------------------------------------------------------------------

// Ensures all GPU buffers are large enough for the current frame's text draws.
// Must be called before end_text, outside the command buffer render pass.
ensure_text :: proc(state: ^VulkanState) -> linux.Errno {
	t := &state.text_renderer
	if len(t.text_draws) == 0 do return nil

	FontQuads :: struct {
		font:  ^Font,
		quads: u32,
	}
	per_font := make([dynamic]FontQuads)
	defer delete(per_font)

	for draw in t.text_draws {
		font := acquire_atlas(state, draw.style.size) or_return
		if font == nil do continue
		found := false
		for &fq in per_font {
			if fq.font == font {
				fq.quads += u32(len(draw.text))
				found = true
				break
			}
		}
		if !found do append(&per_font, FontQuads{font, u32(len(draw.text))})
	}

	for fq in per_font {
		font_ensure_buffers(state, fq.font, fq.quads) or_return
	}
	return nil
}

start_text :: proc(state: ^VulkanState) {
	clear(&state.text_renderer.text_draws)
}

draw_text_top_left :: proc(
	state: ^VulkanState,
	text: string,
	pos: [2]f32,
	style: TextStyle,
	zindex: f32 = 0,
) {
	font, err := acquire_atlas(state, style.size)
	if err != nil || font == nil do return
	scale: f32 = 1
	if style.size != 0 do scale = style.size / font.pixel_size
	draw_text(state, text, {pos.x, pos.y + font.ascent * scale}, style, zindex)
}

draw_text :: proc(
	state: ^VulkanState,
	text: string,
	pos: [2]f32,
	style: TextStyle,
	zindex: f32 = 0,
) {
	append(
		&state.text_renderer.text_draws,
		TextDraw{text = text, pos = pos, style = style, zindex = zindex},
	)
}

end_text :: proc(
	state: ^VulkanState,
	cmd: vk.CommandBuffer,
	surf_w: u32,
	surf_h: u32,
) -> linux.Errno {
	t := &state.text_renderer
	if len(t.text_draws) == 0 do return nil

	slice.stable_sort_by(t.text_draws[:], proc(a, b: TextDraw) -> bool {
		return a.zindex < b.zindex
	})

	// Resolve each draw to its best-matching atlas.
	ResolvedDraw :: struct {
		draw: TextDraw,
		font: ^Font,
	}
	resolved := make([]ResolvedDraw, len(t.text_draws))
	defer delete(resolved)
	for draw, i in t.text_draws {
		font := acquire_atlas(state, draw.style.size) or_return
		resolved[i] = ResolvedDraw{draw, font}
	}

	// Collect unique fonts in first-occurrence order.
	unique_fonts := make([dynamic]^Font)
	defer delete(unique_fonts)
	for r in resolved {
		if r.font == nil do continue
		already := false
		for f in unique_fonts {
			if f == r.font {
				already = true
				break
			}
		}
		if !already do append(&unique_fonts, r.font)
	}
	if len(unique_fonts) == 0 do return nil

	push := [2]f32{f32(surf_w), f32(surf_h)}

	for font in unique_fonts {
		clear(&t.vertices)
		for r in resolved {
			if r.font != font do continue
			draw := r.draw
			scale: f32 = 1
			if draw.style.size != 0 do scale = draw.style.size / font.pixel_size
			pen_x := draw.pos.x
			baseline_y := draw.pos.y

			for ch in draw.text {
				if ch < GLYPH_FIRST || int(ch) >= GLYPH_FIRST + GLYPH_COUNT do continue
				g := font.glyphs[int(ch) - GLYPH_FIRST]
				if g.size.x == 0 || g.size.y == 0 {
					pen_x += g.advance * scale
					continue
				}
				x0 := pen_x + g.offset.x * scale
				y0 := baseline_y + g.offset.y * scale
				x1 := x0 + g.size.x * scale
				y1 := y0 + g.size.y * scale
				corners := [4][2]f32{{x0, y0}, {x1, y0}, {x0, y1}, {x1, y1}}
				uvs := [4][2]f32 {
					{g.uv_min.x, g.uv_min.y},
					{g.uv_max.x, g.uv_min.y},
					{g.uv_min.x, g.uv_max.y},
					{g.uv_max.x, g.uv_max.y},
				}
				for i in 0 ..< 4 {
					append(
						&t.vertices,
						TextVertex{pos = corners[i], uv = uvs[i], color = draw.style.color},
					)
				}
				pen_x += g.advance * scale
			}
		}
		if len(t.vertices) == 0 do continue

		n_quads := u32(len(t.vertices) / 4)
		set_buffer_data(state, &font.vertex_buf, t.vertices[:])

		bind_pipeline(cmd, &t.pipeline, &push, &font.descriptor_set)
		bind_vertex_buffer(cmd, &t.pipeline, &font.vertex_buf)
		bind_index_buffer(cmd, &t.pipeline, &state.quad_index_buf)
		draw_pipeline(cmd, &t.pipeline, n_quads)
	}

	return nil
}

// ---------------------------------------------------------------------------
// Layout helpers
// ---------------------------------------------------------------------------

get_text_bounding_box_top_left :: proc(
	state: ^VulkanState,
	text: string,
	pos: [2]f32,
	style: TextStyle,
) -> Rect {
	font, _ := acquire_atlas(state, style.size)
	if font == nil do return {}
	scale: f32 = 1
	if style.size != 0 do scale = style.size / font.pixel_size
	return get_text_bounding_box(state, text, {pos.x, pos.y + font.ascent * scale}, style)
}

get_text_bounding_box :: proc(
	state: ^VulkanState,
	text: string,
	pos: [2]f32,
	style: TextStyle,
) -> Rect {
	font, _ := acquire_atlas(state, style.size)
	if font == nil do return {}
	scale: f32 = 1
	if style.size != 0 do scale = style.size / font.pixel_size
	total_width: f32
	for ch in text {
		if ch < GLYPH_FIRST || int(ch) >= GLYPH_FIRST + GLYPH_COUNT do continue
		total_width += font.glyphs[int(ch) - GLYPH_FIRST].advance * scale
	}
	return Rect {
		pos = {pos.x, pos.y - font.ascent * scale},
		size = {total_width, (font.ascent - font.descent) * scale},
	}
}

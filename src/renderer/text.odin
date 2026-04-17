package renderer

import "core:fmt"
import "core:mem"
import "core:os"
import "core:sys/linux"
import stbtt "vendor:stb/truetype"
import vk "vendor:vulkan"

FONT_PATH :: "/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf"
FONT_PIXEL_SIZE :: f32(24)

ATLAS_WIDTH :: u32(512)
ATLAS_HEIGHT :: u32(128)
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
	ascent, descent: f32,
	glyphs:          [GLYPH_COUNT]GlyphInfo,
	atlas_image:     vk.Image,
	atlas_memory:    vk.DeviceMemory,
	atlas_view:      vk.ImageView,
	atlas_sampler:   vk.Sampler,
	descriptor_set:  vk.DescriptorSet,
}

TextStyle :: struct {
	font:  ^Font,
	color: [4]f32,
}

Rect :: struct {
	pos:  [2]f32,
	size: [2]f32,
}

TextVertex :: struct #packed {
	pos:   [2]f32,
	uv:    [2]f32,
	color: [4]f32,
}

TextDraw :: struct {
	text:  string,
	pos:   [2]f32,
	style: TextStyle,
}

TextRenderer :: struct {
	text_draws: [dynamic]TextDraw,
	vertices:   [dynamic]TextVertex,
	pool:       vk.DescriptorPool,
	pipeline:   VulkanPipeline(2, TextVertex),
}

// ---------------------------------------------------------------------------
// Initialization / teardown
// ---------------------------------------------------------------------------

initialize_text_renderer :: proc(state: ^VulkanState) -> (err: linux.Errno) {
	t := &state.text_renderer
	t.text_draws = make([dynamic]TextDraw)
	t.vertices = make([dynamic]TextVertex)

	pool_size := vk.DescriptorPoolSize {
		type            = .COMBINED_IMAGE_SAMPLER,
		descriptorCount = 8,
	}
	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets       = 8,
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
		starting_capacity   = 256,
		descriptor_bindings = descriptor_bindings,
	}
	initialize_rendering_pipeline(state, &t.pipeline, &info) or_return

	fmt.printfln("text: renderer initialized")
	return nil
}

destroy_text_renderer :: proc(state: ^VulkanState) {
	t := &state.text_renderer
	destroy_pipeline(state, &t.pipeline)
	if t.pool != 0 {
		vk.DestroyDescriptorPool(state.device, t.pool, nil)
		t.pool = 0
	}
	delete(t.text_draws)
	delete(t.vertices)
}

load_font :: proc(state: ^VulkanState) -> (font: ^Font, err: linux.Errno) {
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

	bitmap := make([]u8, ATLAS_WIDTH * ATLAS_HEIGHT)
	defer delete(bitmap)

	chardata: [GLYPH_COUNT]stbtt.bakedchar
	result := stbtt.BakeFontBitmap(
		raw_data(font_data),
		0,
		FONT_PIXEL_SIZE,
		raw_data(bitmap),
		i32(ATLAS_WIDTH),
		i32(ATLAS_HEIGHT),
		GLYPH_FIRST,
		GLYPH_COUNT,
		&chardata[0],
	)
	if result <= 0 {
		fmt.eprintln(
			"text: BakeFontBitmap failed — atlas too small or bad font, result:",
			result,
		)
		err = .EINVAL
		return
	}

	line_gap: f32
	stbtt.GetScaledFontVMetrics(
		raw_data(font_data),
		0,
		FONT_PIXEL_SIZE,
		&font.ascent,
		&font.descent,
		&line_gap,
	)

	for i in 0 ..< GLYPH_COUNT {
		c := chardata[i]
		w := f32(c.x1 - c.x0)
		h := f32(c.y1 - c.y0)
		font.glyphs[i] = GlyphInfo {
			uv_min  = {f32(c.x0) / f32(ATLAS_WIDTH), f32(c.y0) / f32(ATLAS_HEIGHT)},
			uv_max  = {f32(c.x1) / f32(ATLAS_WIDTH), f32(c.y1) / f32(ATLAS_HEIGHT)},
			offset  = {c.xoff, c.yoff},
			size    = {w, h},
			advance = c.xadvance,
		}
	}

	upload_font_atlas(state, font, bitmap) or_return

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

	fmt.printfln("text: font loaded (%dx%d atlas)", ATLAS_WIDTH, ATLAS_HEIGHT)
	return
}

destroy_font :: proc(state: ^VulkanState, font: ^Font) {
	if font == nil do return
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

@(private)
upload_font_atlas :: proc(state: ^VulkanState, font: ^Font, bitmap: []u8) -> (err: linux.Errno) {
	subresource_range := vk.ImageSubresourceRange {
		aspectMask = {.COLOR},
		levelCount = 1,
		layerCount = 1,
	}

	image_info := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		format = .R8_UNORM,
		extent = {width = ATLAS_WIDTH, height = ATLAS_HEIGHT, depth = 1},
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
	vk.MapMemory(state.device, staging_mem, 0, staging_size, {}, &mapped)
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
		imageExtent = {width = ATLAS_WIDTH, height = ATLAS_HEIGHT, depth = 1},
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

start_text :: proc(state: ^VulkanState) {
	clear(&state.text_renderer.text_draws)
}

draw_text_top_left :: proc(state: ^VulkanState, text: string, pos: [2]f32, style: TextStyle) {
	draw_text(state, text, {pos.x, pos.y + style.font.ascent}, style)
}

draw_text :: proc(state: ^VulkanState, text: string, pos: [2]f32, style: TextStyle) {
	assert(
		len(state.text_renderer.text_draws) == 0 ||
		state.text_renderer.text_draws[0].style.font == style.font,
		"all draw_text calls in a frame must use the same font",
	)
	append(&state.text_renderer.text_draws, TextDraw{text = text, pos = pos, style = style})
}

end_text :: proc(
	state: ^VulkanState,
	cmd: vk.CommandBuffer,
	surf_w: u32,
	surf_h: u32,
) -> linux.Errno {
	t := &state.text_renderer
	if len(t.text_draws) == 0 do return nil

	clear(&t.vertices)
	for draw in t.text_draws {
		font := draw.style.font
		pen_x := draw.pos.x
		baseline_y := draw.pos.y

		for r in draw.text {
			if r < GLYPH_FIRST || int(r) >= GLYPH_FIRST + GLYPH_COUNT do continue
			g := font.glyphs[int(r) - GLYPH_FIRST]
			if g.size.x == 0 || g.size.y == 0 {
				pen_x += g.advance
				continue
			}

			x0 := pen_x + g.offset.x
			y0 := baseline_y + g.offset.y
			x1 := x0 + g.size.x
			y1 := y0 + g.size.y

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
			pen_x += g.advance
		}
	}

	if len(t.vertices) == 0 do return nil

	update_pipeline_verticies(state, &t.pipeline, t.vertices[:]) or_return

	push := [2]f32{f32(surf_w), f32(surf_h)}
	font := t.text_draws[0].style.font
	apply_pipeline(cmd, &t.pipeline, &push, &font.descriptor_set)

	return nil
}

// ---------------------------------------------------------------------------
// Layout helpers
// ---------------------------------------------------------------------------

get_text_bounding_box_top_left :: proc(text: string, pos: [2]f32, style: TextStyle) -> Rect {
	return get_text_bounding_box(text, {pos.x, pos.y + style.font.ascent}, style)
}

get_text_bounding_box :: proc(text: string, pos: [2]f32, style: TextStyle) -> Rect {
	font := style.font
	total_width: f32
	for r in text {
		if r < GLYPH_FIRST || int(r) >= GLYPH_FIRST + GLYPH_COUNT do continue
		total_width += font.glyphs[int(r) - GLYPH_FIRST].advance
	}
	return Rect {
		pos = {pos.x, pos.y - font.ascent},
		size = {total_width, font.ascent - font.descent},
	}
}

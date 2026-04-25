# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

**Build and run:**
```bash
./build.sh          # compiles shaders with glslc, then builds dist/odin (demo) and dist/sudoku
./dist/odin         # run demo app (requires a running Wayland compositor)
./dist/sudoku       # run sudoku app (requires a running Wayland compositor)
```

**Regenerate protocol bindings after changing the generator or adding a new XML:**
```bash
./generate_protocol.sh   # builds wayland_gen, then runs it on wayland.xml and xdg-shell.xml
```

No tests exist yet.

## Architecture

This is a from-scratch Wayland client written in Odin. There are four major layers: a **code generator**, a **platform layer**, a **Vulkan renderer**, and **apps**.

---

### Code generator (`wayland_gen/`)

Reads Wayland XML protocol files and emits one Odin package per interface into `src/wayland_protocol/`. The pipeline is:

```
XML → parse.odin → IR (ir.odin) → validate.odin → generate.odin → src/wayland_protocol/<iface>/<iface>.odin
```

`generate.odin` is the main file to edit when changing what gets emitted. Key procs:
- `collect_imports` — decides which imports a generated file needs
- `emit_request` — emits a request proc (client→server)
- `emit_event` / `emit_event_handler` — emits `OnXxx` proc type aliases
- `emit_event_handlers_struct` — emits the `EventHandlers` struct
- `emit_handle_event_proc` — emits the `handle_event` dispatcher

`names.odin` handles name conversion (snake_case → CamelCase, UPPER_SNAKE, etc.).

**After any change to `wayland_gen/`, run `./generate_protocol.sh` to regenerate and then rebuild with `./build.sh`.**

### Generated protocol packages (`src/wayland_protocol/<iface>/`)

Each package is auto-generated — **do not edit by hand**. Every package exports:

- Opcode constants (`FOO_REQUEST_OPCODE`, `BAR_EVENT_OPCODE`)
- Request procs (e.g., `wl_compositor.create_surface(...)`)
- `OnXxx` proc type aliases for each event
- `EventHandlers` struct with one nullable proc field per event
- `handle_event(object_id, opcode, msg, msg_len, handlers_raw, user_data, fds)` — dispatches to the registered handler if non-nil

`src/wayland_protocol/` is git-ignored; regenerate it with `./generate_protocol.sh`. Referenced via the `wayland_protocol` collection (e.g., `wl_display "wayland_protocol:wl_display"`).

---

### Wire I/O

**`src/buf_writer/`** — stack-allocated write buffer. `Writer($N)` holds a fixed `[N]u8` array. `initialize` writes the message header (object id, opcode, announced size). Each `write_*` proc appends data and updates the announced size in place. `send` / `send_with_fd` flush over the socket.

**`src/buf_reader/`** — mirrors buf_writer for reading. All procs take `(buf: ^^u8, buf_size: ^int)` and advance the pointer in place. `read_string` allocates and strips the null terminator (caller must `delete`). `read_array` allocates the byte slice (caller must `delete`).

**`src/utils/`** — `roundup_4` for Wayland's 4-byte alignment requirement.

**`src/constants/`** — `BUF_WRITER_SIZE_BASE = 128`, `BUF_WRITER_SIZE_STRING = 512` (use the larger one for requests that include strings). Also `NUM_CELLS = 10`, `COLOR_CHANNELS = 4`.

### Wayland wire format notes

- Strings: u32 length prefix (includes null terminator) + content + padded to 4 bytes. `read_string` returns a clean string without the null; callers must include `\x00` when writing.
- Arrays: same layout but the length does not include any null terminator.
- `fd` args are transmitted as ancillary data via `SCM_RIGHTS`, not inline. Generated `handle_event` procs skip `fd`-typed args from the inline message body.

---

### Platform layer (`src/platform/`, `src/platform_types/`)

**`src/platform_types/platform_types.odin`** — shared types used by the platform and apps:
- `FrameInfo` — per-frame snapshot: `width`, `height`, `pointer: Pointer`, `keyboard: Keyboard`
- `Pointer` — `x`, `y`, `left_button_down/pressed/released`
- `Keyboard` — `keys_pressed: [16]u32` (evdev keycodes), `n_keys: u32`. Keycodes are raw Linux evdev values (KEY_1=2 through KEY_9=10, KEY_0=11, KEY_BACKSPACE=14, KEY_DELETE=111).

**`src/platform/platform.odin`** — thin wrapper that re-exports the Wayland backend. Key procs: `init`, `pump`, `consume_frame_info`, `ready_for_frame`, `present_dmabuf`, `skip_frame`, `shutdown`.

**`src/platform/wayland/`** — Wayland-specific implementation:
- `state.odin` — `Client` struct (holds all Wayland object handles, pointer/keyboard state, surface state). `consume_frame_info` copies current input state into a `FrameInfo` and resets single-frame events (`left_button_pressed`, `n_keys`).
- `pointer.odin` — `wl_pointer_handlers`: accumulates `x/y`, `left_button_down/pressed/released` into `client.pointer`.
- `keyboard.odin` — `wl_keyboard_handlers`: `on_key` appends pressed evdev keycodes to `client.keyboard.keys_pressed`.
- `surface.odin`, `display.odin`, `registry.odin`, `seat.odin`, `buffer.odin`, `dmabuf.odin`, `output.odin`, `shm.odin` — Wayland protocol setup and DMA-buf surface management.

`register_event_handler(client, object_id, handlers, handle_event)` registers a handler; `user_data` defaults to `client` if nil, so handlers can cast `user_data` to `^Client`.

---

### Runner (`src/runner/runner.odin`)

`runner.run(AppConfig)` is the main loop used by all apps. It:
1. Initialises the platform and logger
2. Calls `on_init` once the surface is ready (with `max_width`/`max_height`)
3. Each frame: calls `platform.consume_frame_info`, then `on_frame`
4. Calls `on_shutdown` on exit

`AppConfig` holds `title`, `min_w/h`, `log_blacklist`, `user_data`, and the three callbacks.

---

### Renderer (`src/renderer/`)

A Vulkan renderer that outputs frames as DMA-buf images for the compositor.

#### GPU buffer abstraction (`buffer.odin`)

`VulkanBuffer($Stage, $Type)` — a persistently-mapped HOST_VISIBLE buffer. `capacity` is in **element count** (not bytes); Vulkan allocates `capacity * size_of(Type)` bytes internally.

Key procs:
- `allocate_buffer(state, buffer, capacity)` — allocates and maps
- `destroy_buffer(state, buffer)`
- `set_buffer_data(state, buffer, data)` — copies data and flushes; calls `ensure_buffer_capacity` which grows (never shrinks)
- `ensure_buffer_capacity(state, buffer, capacity)` — reallocates if needed
- `flush_buffer(state, buffer)` — flushes mapped range

`QuadIndexBuffer :: VulkanBuffer(.INDEX_BUFFER, u16)` — specialisation for quad index buffers using the standard `0,1,2, 2,1,3` pattern per quad.
- `allocate_quad_index_buffer(state, buffer, n_quads)` — allocates and fills with quad indices
- `ensure_quad_index_buffer(state, buffer, n_quads)` — grows if needed

#### Frame buffer (`frame_buffer.odin`)

`VulkanFrameBuffer` — a pair of Vulkan images (OPTIMAL render target + LINEAR DMA-buf export) with associated `vk.Framebuffer`. Allocated with `allocate_frame_buffer(state, w, h)`, freed with `free_frame_buffer`.

#### Pipeline abstraction (`pipeline.odin`)

`VulkanPipeline($PushConstantCount, $VertexType)` — holds shader modules, pipeline layout, and the Vulkan pipeline. `NoVertex` is used for pipelines that generate geometry in the vertex shader (no vertex buffer).

`VulkanPipelineInfo` — `vertex_spv`, `fragment_spv`, `descriptor_bindings`.

Draw sequence inside a render pass:
```
bind_pipeline(cmd, pipeline, push_data, descriptor_set?)
bind_vertex_buffer(cmd, pipeline, vertex_buf)   // skip for NoVertex pipelines
bind_index_buffer(cmd, pipeline, index_buf)     // skip for NoVertex pipelines
draw_pipeline(cmd, pipeline, n_quads)
```

`bind_pipeline` sets `pipeline.bound = true`; `draw_pipeline` resets it. The `bound` flag is asserted by `bind_vertex_buffer`, `bind_index_buffer`, and `draw_pipeline`.

#### VulkanState (`renderer.odin`)

`VulkanState` holds the full Vulkan context. Key fields:
- `grid_pipeline: VulkanPipeline(5, NoVertex)` — fullscreen SDF grid
- `quad_index_buf: QuadIndexBuffer` — **shared** index buffer used by all quad-drawing pipelines
- `shape_renderer: ShapeRenderer`
- `text_renderer: TextRenderer`

Per-frame flow (called by the app):
```
start_frame(state, frame_buf, params)   // begins command buffer and render pass
draw_grid(state)                         // optional: draws the background grid
// draw_shape / draw_text_* calls accumulate data
end_frame(state)                         // calls ensure_shapes, ensure_text, end_shapes,
                                         // end_text, ends render pass, submits, waits
```

**Buffer ensuring happens at the start of `end_frame`** (via `ensure_shapes` and `ensure_text`), before any draw commands are recorded, so buffer reallocation never invalidates already-recorded command buffer handles.

#### Shape renderer (`shapes.odin`)

`ShapeRenderer` — accumulates `ShapeData` per frame via `draw_shape`, sorted by `zindex` and uploaded as `ShapeVertex` quads. Supported shapes: `LineData`, `RectData`, `RoundedRectData`, `TriangleData`, `OvalData`, `CircleData`.

`ensure_shapes(state)` — pre-ensures vertex and index buffers before command recording.
`end_shapes(state, cmd, w, h)` — uploads vertex data and records draw commands.

Each shape expands to exactly 4 vertices (a bounding quad); the fragment shader evaluates the SDF of the actual shape.

#### Text renderer (`text.odin`)

`TextRenderer` — multi-atlas text renderer that auto-manages font atlases.

**Atlas management:**
- `acquire_atlas(state, size)` — returns a cached `^Font` within `ATLAS_SIZE_TOLERANCE = 5px` of `size`, or loads a new one. Calling with a non-zero size also sets `TextRenderer.default_size` (used when `style.size == 0`). Default is 16px if `acquire_atlas` is never called.
- `load_font(state, pixel_size)` — loads the font from `FONT_PATH`, packs glyphs with stb_truetype, uploads the atlas image to GPU, allocates a descriptor set.
- `destroy_font(state, font)`

**Per-frame flow:**
1. `start_text(state)` — clears `text_draws`; clears (not deletes) the `font_draws` map so per-font `[dynamic]TextDraw` allocations are reused across frames.
2. `draw_text(state, text, pos, style, zindex)` / `draw_text_top_left(...)` — accumulate draws.
3. `ensure_text(state)` — sorts draws by zindex, builds `font_draws: map[^Font][dynamic]TextDraw` in one pass, calls `font_ensure_buffers` per font.
4. `end_text(state, cmd, w, h)` — iterates `font_draws`, tessellates vertices per font, uploads, and records draw commands.

`font_ensure_buffers(state, font, needed_quads)` — grows the font's vertex buffer (with 2× headroom) and the shared `state.quad_index_buf` when needed.

`TextStyle` — `color: [4]f32`, `size: f32`. Size 0 uses `default_size`.

---

### Apps

#### Demo (`apps/demo/`)

Demonstrates shapes and text rendering with draggable scene objects. `State` holds `VulkanState`, `VulkanFrameBuffer`, and a `[dynamic]SceneObject`. Each `SceneObject` has a `Renderable` (either `ShapeData` or `TextData`), an optional `layout_proc`, and bounds. The layout system repositions objects each frame; dragging is handled via pointer events.

#### Sudoku (`apps/sudoku/`)

Interactive Sudoku board. `State` holds:
- `board: [81]int` — 0 = empty, 1–9 = digit
- `selected_cell: int` — index 0–80, or -1
- `hovered_cell: int` — index 0–80, or -1

Input handling in `render_frame`:
- Hover: computed each frame from pointer position against the grid geometry
- Click: selects the hovered cell; clicking the selected cell deselects it
- Digit keys 1–9 (evdev 2–10): write to selected cell
- KEY_0 (11), KEY_BACKSPACE (14), KEY_DELETE (111): clear selected cell

Rendering in `draw_grid`: background rect → hover/selected overlays (10px inset, semi-transparent black) → thick box/band lines → thin cell lines → digits. Submission order determines draw order within the same z-index tier; text always renders after all shapes.

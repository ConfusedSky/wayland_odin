# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

**Build and run the client:**
```bash
./build        # compiles wayland.odin → ./odin (debug, no optimization)
./odin         # run (requires a running Wayland compositor)
```

**Regenerate protocol bindings after changing the generator or adding a new XML:**
```bash
./generate_protocol   # builds wayland_gen, then runs it on wayland.xml and xdg-shell.xml
```

**Build the generator only:**
```bash
odin build ./wayland_gen
```

No tests exist yet.

## Architecture

This is a from-scratch Wayland client written in Odin. There are two largely independent pieces: a **code generator** and the **client application**.

### Code generator (`wayland_gen/`)

Reads Wayland XML protocol files and emits one Odin package per interface into `wayland_protocol/`. The pipeline is:

```
XML → parse.odin → IR (ir.odin) → validate.odin → generate.odin → wayland_protocol/<iface>/<iface>.odin
```

`ir.odin` defines the IR structs (`Protocol`, `Interface`, `Request`, `Event`, `Enum`, `Arg`).

`generate.odin` is the main file to edit when changing what gets emitted. Key procs:
- `collect_imports` — decides which imports a generated file needs
- `emit_request` — emits a request proc (client→server)
- `emit_event` / `emit_event_handler` — emits `OnXxx` proc type aliases
- `emit_event_handlers_struct` — emits the `EventHandlers` struct
- `emit_handle_event_proc` — emits the `handle_event` dispatcher

`names.odin` handles name conversion (snake_case → CamelCase, UPPER_SNAKE, etc.).

**After any change to `wayland_gen/`, run `./generate_protocol` to regenerate and then rebuild with `./build`.**

### Generated protocol packages (`wayland_protocol/<iface>/`)

Each package is auto-generated — **do not edit by hand**. Every package exports:

- Opcode constants (`FOO_REQUEST_OPCODE`, `BAR_EVENT_OPCODE`)
- Request procs (e.g., `wl_compositor.create_surface(socket, object_id, new_id)`)
- `OnXxx` proc type aliases for each event
- `EventHandlers` struct with one nullable proc field per event
- `handle_event(object_id, opcode, msg, msg_len, handlers_raw, user_data)` — reads wire args via `buf_reader`, prints a debug line with `[handled]`/`[unhandled]`, and dispatches to the handler if non-nil

`wayland_protocol/` is git-ignored; regenerate it with `./generate_protocol`.

### Wire I/O

**`buf_writer/`** — stack-allocated write buffer. `Writer($N)` holds a fixed `[N]u8` array. `initialize` writes the message header (object id, opcode, announced size). Each `write_*` proc appends data and updates the announced size field in place. `send` / `send_with_fd` flush over the socket.

**`buf_reader/`** — mirrors buf_writer for reading. All procs take `(buf: ^^u8, buf_size: ^int)` and advance the pointer in place. `read_string` allocates and strips the null terminator (caller must `delete`). `read_array` allocates the byte slice (caller must `delete`).

**`utils/`** — `roundup_4` for Wayland's 4-byte alignment requirement.

**`constants/`** — `BUF_WRITER_SIZE_BASE = 128`, `BUF_WRITER_SIZE_STRING = 512` (use the larger one for requests that include strings).

### Client application (`wayland.odin`)

Single-file client in `package Main`. Key concepts:

- `state_t` holds all Wayland object IDs (as `u32`) plus `socket_fd` and shared-memory state. Passed as `rawptr user_data` through every event callback.
- `event_handlers` — a fixed array of `RegisteredEventHandler` entries, one per active interface. Each entry holds the `handle_event` proc pointer, a `get_object` lambda that extracts the object's current ID from `state_t`, and a pointer to that interface's `EventHandlers` struct.
- `wayland_handle_message` — reads one message header, finds the matching entry in `event_handlers` by comparing `object_id` against each `get_object(state)` result, and dispatches.
- `registry_bind` is hand-written (not generated) because the `wl_registry.bind` request has an untyped `new_id` argument requiring special handling. It appends `\x00` to the interface string before writing, because `buf_reader.read_string` strips null terminators.

### Wayland wire format notes

- Strings: u32 length prefix (includes null terminator) + content + padding to 4 bytes. `read_string` returns a clean string without the null; `write_string` / `write_data_raw` expect the caller to include `\x00` when the protocol requires it.
- Arrays: same layout but the length does not include any null terminator.
- `fd` args are transmitted as ancillary data via `SCM_RIGHTS`, not inline. Generated `handle_event` procs emit a comment and skip `fd`-typed event args.

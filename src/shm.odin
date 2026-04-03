package Main

import constants "./constants"
import "core:fmt"
import "core:os"
import "core:sys/linux"
import wl_shm "wayland_protocol/wl_shm"
import wl_shm_pool "wayland_protocol/wl_shm_pool"

ShmPool :: struct {
	wl_shm_pool: wl_shm_pool.t,
	size:        u32,
	fd:          linux.Fd,
	data:        ^u8,
}

wl_shm_handlers: wl_shm.EventHandlers

initialize_wl_shm :: proc(state: ^state_t, name: u32, version: u32) {
	shm, err := wl_shm.from_global(&state.wl_registry, name, version)
	if err != nil do os.exit(int(err))
	state.wl_shm = shm
	register_event_handler(state, state.wl_shm.id, &wl_shm_handlers, wl_shm.handle_event)
}

initialize_wl_shm_pool :: proc(shm: ^wl_shm.t, shm_pool: ^ShmPool, size: u32) {
	fd, data := create_shared_memory_file(size)
	pool, err := wl_shm.create_pool(shm, fd, i32(size))
	if err != nil do os.exit(int(err))

	shm_pool.wl_shm_pool = pool
	shm_pool.fd = fd
	shm_pool.data = data
	shm_pool.size = size
}

cleanup_wl_shm_pool :: proc(shm_pool: ^ShmPool) {
	assert(shm_pool.wl_shm_pool.id > 0)

	err := wl_shm_pool.destroy(&shm_pool.wl_shm_pool)
	if err != nil do os.exit(int(err))
	cleanup_shared_memory_file(shm_pool.fd, shm_pool.data, shm_pool.size)
	shm_pool^ = {}
}

create_shared_memory_file :: proc(size: u32) -> (linux.Fd, ^u8) {
	assert(size > 0)

	fd, memfd_err := linux.memfd_create("shm_file", {})

	if fd == -1 || memfd_err != nil {
		fmt.eprintln("open failed")
		os.exit(int(memfd_err))
	}

	ftruncate_err := linux.ftruncate(fd, i64(size))
	if ftruncate_err != nil {
		fmt.eprintln("ftruncate failed")
		os.exit(int(ftruncate_err))
	}

	// this needs to be mmunmaped and closed if the screen is resized and this
	// function is used to create a new memory file
	data, mmap_err := linux.mmap(uintptr(0), uint(size), {.READ, .WRITE}, {.SHARED}, fd)

	if mmap_err != nil {
		fmt.eprintln("mmap failed")
		os.exit(int(mmap_err))
	}

	data_view := (^u8)(data)
	assert(data_view != (^u8)(~uintptr(0)))
	assert(data_view != nil)
	return fd, data_view
}

cleanup_shared_memory_file :: proc(fd: linux.Fd, data: ^u8, size: u32) {
	assert(data != nil)
	assert(size > 0)
	assert(fd > 0)

	munmap_err := linux.munmap(rawptr(data), uint(size))

	if munmap_err != nil {
		fmt.eprintln("munmap failed")
		os.exit(int(munmap_err))
	}

	close_err := linux.close(fd)

	if close_err != nil {
		fmt.eprintln("close failed")
		os.exit(int(close_err))
	}
}

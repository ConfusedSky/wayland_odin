package Main

import constants "./constants"
import "core:fmt"
import "core:os"
import "core:sys/linux"
import wl_shm "wayland_protocol/wl_shm"

wl_shm_handlers: wl_shm.EventHandlers

create_shared_memory_file :: proc(state: ^state_t) {
	assert(state.max_w > 0)
	assert(state.max_h > 0)
	assert(state.max_stride == state.max_w * constants.COLOR_CHANNELS)
	assert(state.shm_pool_size > 0)
	assert(state.shm_pool_size == state.max_h * state.max_stride)

	fd, memfd_err := linux.memfd_create("shm_file", {})

	if fd == -1 || memfd_err != nil {
		fmt.eprintln("open failed")
		os.exit(int(memfd_err))
	}

	ftruncate_err := linux.ftruncate(fd, i64(state.shm_pool_size))
	if ftruncate_err != nil {
		fmt.eprintln("ftruncate failed")
		os.exit(int(ftruncate_err))
	}

	// this needs to be mmunmaped and closed if the screen is resized and this
	// function is used to create a new memory file
	data, mmap_err := linux.mmap(
		uintptr(0),
		uint(state.shm_pool_size),
		{.READ, .WRITE},
		{.SHARED},
		fd,
	)

	if mmap_err != nil {
		fmt.eprintln("mmap failed")
		os.exit(int(mmap_err))
	}

	state.shm_pool_data = (^u8)(data)
	assert(state.shm_pool_data != (^u8)(~uintptr(0)))
	assert(state.shm_pool_data != nil)
	state.shm_fd = fd
}

cleanup_shared_memory_file :: proc(state: ^state_t) {
	assert(state.shm_pool_data != nil)
	assert(state.shm_pool_size > 0)
	assert(state.shm_fd > 0)

	munmap_err := linux.munmap(rawptr(state.shm_pool_data), uint(state.shm_pool_size))
	state.shm_pool_data = nil
	state.shm_pool_size = 0

	if munmap_err != nil {
		fmt.eprintln("munmap failed")
		os.exit(int(munmap_err))
	}

	close_err := linux.close(state.shm_fd)

	if close_err != nil {
		fmt.eprintln("close failed")
		os.exit(int(close_err))
	}

	state.shm_fd = 0
}

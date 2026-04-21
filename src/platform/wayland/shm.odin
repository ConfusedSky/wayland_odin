package wayland

import wl_shm "../../wayland_protocol/wl_shm"
import wl_shm_pool "../../wayland_protocol/wl_shm_pool"
import "core:fmt"
import "core:sys/linux"

ShmPool :: struct {
	wl_shm_pool: wl_shm_pool.t,
	size:        u32,
	fd:          linux.Fd,
	data:        ^u8,
}

wl_shm_handlers: wl_shm.EventHandlers

initialize_wl_shm :: proc(client: ^Client, name: u32, version: u32) -> Errno {
	client.wl_shm = wl_shm.from_global(&client.wl_registry, name, version) or_return
	wl_shm_handlers.logger = &client.logger
	register_event_handler(client, client.wl_shm.id, &wl_shm_handlers, wl_shm.handle_event)
	return nil
}

initialize_wl_shm_pool :: proc(shm: ^wl_shm.t, shm_pool: ^ShmPool, size: u32) -> Errno {
	fd, data := create_shared_memory_file(size) or_return
	shm_pool.wl_shm_pool = wl_shm.create_pool(shm, fd, i32(size)) or_return
	shm_pool.fd = fd
	shm_pool.data = data
	shm_pool.size = size
	return nil
}

cleanup_wl_shm_pool :: proc(shm_pool: ^ShmPool) -> Errno {
	assert(shm_pool.wl_shm_pool.id > 0)
	wl_shm_pool.destroy(&shm_pool.wl_shm_pool) or_return
	cleanup_shared_memory_file(shm_pool.fd, shm_pool.data, shm_pool.size) or_return
	shm_pool^ = {}
	return nil
}

create_shared_memory_file :: proc(size: u32) -> (linux.Fd, ^u8, Errno) {
	assert(size > 0)

	fd, memfd_err := linux.memfd_create("shm_file", {})
	if fd == -1 || memfd_err != nil {
		fmt.eprintln("memfd_create failed")
		return -1, nil, memfd_err
	}

	ftruncate_err := linux.ftruncate(fd, i64(size))
	if ftruncate_err != nil {
		fmt.eprintln("ftruncate failed")
		return -1, nil, ftruncate_err
	}

	data, mmap_err := linux.mmap(uintptr(0), uint(size), {.READ, .WRITE}, {.SHARED}, fd)
	if mmap_err != nil {
		fmt.eprintln("mmap failed")
		return -1, nil, mmap_err
	}

	data_view := (^u8)(data)
	assert(data_view != (^u8)(~uintptr(0)))
	assert(data_view != nil)
	return fd, data_view, nil
}

cleanup_shared_memory_file :: proc(fd: linux.Fd, data: ^u8, size: u32) -> Errno {
	assert(data != nil)
	assert(size > 0)
	assert(fd > 0)

	munmap_err := linux.munmap(rawptr(data), uint(size))
	if munmap_err != nil {
		fmt.eprintln("munmap failed")
		return munmap_err
	}

	close_err := linux.close(fd)
	if close_err != nil {
		fmt.eprintln("close failed")
		return close_err
	}
	return nil
}

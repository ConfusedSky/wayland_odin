package cmsg

Cmsghdr :: struct {
	cmsg_len:   uint,
	cmsg_level: i32,
	cmsg_type:  i32,
}

SCM_RIGHTS: i32 : 1

CMSG_ALIGN :: proc(len: $T) -> T {
	return (len + size_of(u64) - 1) & (~(T(size_of(u64) - 1)))
}

CMSG_SPACE :: proc(len: $T) -> T {
	return CMSG_ALIGN(len) + CMSG_ALIGN(size_of(Cmsghdr))
}

CMSG_LEN :: proc(len: $T) -> T {
	return len + CMSG_ALIGN(size_of(Cmsghdr))
}

package utils

import "base:intrinsics"

roundup_4 :: proc(n: $T) -> T where intrinsics.type_is_numeric(T) {
	return T(int((n) + 3) & -4)
}

cstring_len :: proc(s: $T) -> int {
	return size_of(s) - 1
}

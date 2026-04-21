package platform_types

import runtime_log "../runtime_log"

InitParams :: struct {
	title:  string,
	min_w:  i32,
	min_h:  i32,
	logger: ^runtime_log.Logger,
}

FrameInfo :: struct {
	width:   u32,
	height:  u32,
	pointer: Pointer,
}

Pointer :: struct {
	x:                    f64,
	y:                    f64,
	left_button_down:     bool,
	left_button_pressed:  bool,
	left_button_released: bool,
}

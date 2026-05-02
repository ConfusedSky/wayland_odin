package renderer

RENDERDOC :: #config(RENDERDOC, false)

when RENDERDOC {
	RenderDocAPI :: struct {
		GetAPIVersion:              proc "c" (major, minor, patch: ^i32),
		SetCaptureOptionU32:        proc "c" (opt: i32, val: u32) -> i32,
		SetCaptureOptionF32:        proc "c" (opt: i32, val: f32) -> i32,
		GetCaptureOptionU32:        proc "c" (opt: i32) -> u32,
		GetCaptureOptionF32:        proc "c" (opt: i32) -> f32,
		SetFocusToggleKeys:         proc "c" (keys: rawptr, num: i32),
		SetCaptureKeys:             proc "c" (keys: rawptr, num: i32),
		GetOverlayBits:             proc "c" () -> u32,
		MaskOverlayBits:            proc "c" (And: u32, Or: u32),
		Shutdown:                   proc "c" (),
		UnloadCrashHandler:         proc "c" (),
		SetCaptureFilePathTemplate: proc "c" (path: cstring),
		GetCaptureFilePathTemplate: proc "c" () -> cstring,
		GetNumCaptures:             proc "c" () -> u32,
		GetCapture:                 proc "c" (
			idx: u32,
			filename: cstring,
			pathlength: ^u32,
			timestamp: ^u64,
		) -> u32,
		TriggerCapture:             proc "c" (),
		IsTargetControlConnected:   proc "c" () -> u32,
		LaunchReplayUI:             proc "c" (connect: u32, cmdline: cstring) -> u32,
		SetActiveWindow:            proc "c" (device: rawptr, wnd: rawptr),
		StartFrameCapture:          proc "c" (device: rawptr, wnd: rawptr),
		IsFrameCapturing:           proc "c" () -> u32,
		EndFrameCapture:            proc "c" (device: rawptr, wnd: rawptr),
		TriggerMultiFrameCapture:   proc "c" (num_frames: u32),
		SetCaptureFileComments:     proc "c" (file_path: cstring, comments: cstring),
		DiscardFrameCapture:        proc "c" (device: rawptr, wnd: rawptr) -> u32,
	}
}

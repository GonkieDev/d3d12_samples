package utils

import "core:log"
import "base:runtime"
import win32 "core:sys/windows"
import dx "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"
import sdl "vendor:sdl2"

ENABLE_GPU_VALIDATION :: ODIN_DEBUG

// Util check
check :: proc(res: dx.HRESULT, message: string) -> bool {
	if (res >= 0) do return true
	log.errorf("%v. Error code: %0x\n", message, u32(res))
	return false
}

// Util enable debug layer and validation
enable_debug_layer :: proc(
	flags: dx.GPU_BASED_VALIDATION_FLAGS,
) -> (
	debug_controller: ^dx.IDebug,
	ok: bool,
) {
	hr: dx.HRESULT

	// Create debug controller
	hr = dx.GetDebugInterface(dx.IDebug_UUID, (^rawptr)(&debug_controller))
	check(hr, "Failed to create debug controller") or_return
	debug_controller->EnableDebugLayer()

	{
		when ENABLE_GPU_VALIDATION {
			debug3: ^dx.IDebug3
			defer (debug3->Release())
			hr = debug_controller->QueryInterface(dx.IDebug3_UUID, (^rawptr)(&debug3))
			check(hr, "Failed to query interface of IDebug3") or_return
			debug3->SetEnableGPUBasedValidation(true)
			debug3->SetGPUBasedValidationFlags(flags)
		}
	}

	return debug_controller, true
}

@private
default_message_callback_logger: log.Logger

default_message_callback :: proc "c" (
	Category: dx.MESSAGE_CATEGORY,
	Severity: dx.MESSAGE_SEVERITY,
	ID: dx.MESSAGE_ID,
	pDescription: cstring,
	pContext: rawptr,
) {
	context = runtime.default_context()
	context.logger = default_message_callback_logger
	log.info(pDescription)
}

// cookie = thing you need so you can unregister
register_debug_message_callback :: proc(device: ^dx.IDevice, callback: dx.PFN_MESSAGE_CALLBACK) -> (cookie: u32, ok: bool) {
	hr: dx.HRESULT

	// Get info queue
	infoQueue: ^dx.IInfoQueue1
	hr = device->QueryInterface(dx.IInfoQueue1_UUID, (^rawptr)(&infoQueue))
	check(hr, "IInfoQueue1 not supported") or_return
	defer(infoQueue->Release())

	hr = infoQueue->RegisterMessageCallback(callback, {}, nil, &cookie)
	check(hr, "Failed to register debug message callback") or_return

	default_message_callback_logger = context.logger
	
	return cookie, true
}

unregister_debug_message_callback :: proc(device: ^dx.IDevice, cookie: u32) -> bool {
	hr: dx.HRESULT
	
		// Get info queue
	infoQueue: ^dx.IInfoQueue1
	hr = device->QueryInterface(dx.IInfoQueue1_UUID, (^rawptr)(&infoQueue))
	check(hr, "IInfoQueue1 not supported") or_return
	defer(infoQueue->Release())

	hr = infoQueue->UnregisterMessageCallback(cookie)
	check(hr, "Failed to unregister debug message callback") or_return

	return true
}

//
// SDL Utils
//

hwnd_from_window :: proc(window: ^sdl.Window) -> dxgi.HWND {
	wm_info: sdl.SysWMinfo
	sdl.GetWindowWMInfo(window, &wm_info)
	return dxgi.HWND(wm_info.info.win.window)
}

client_size_from_window :: proc(window: ^sdl.Window) -> [2]i32 {
	res: [2]i32
	sdl.GetWindowSize(window, &res[0], &res[1])
	return res
}


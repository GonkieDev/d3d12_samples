package triangle

// Credits to: https://gist.github.com/jakubtomsu/ecd83e61976d974c7730f9d7ad3e1fd0

import "core:log"
import dx "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"
import sdl "vendor:sdl2"

NUM_RENDERTARGETS :: 2

State :: struct {
	debug_ctrl:          ^dx.IDebug,
	factory:             ^dxgi.IFactory4,
	adapter:             ^dxgi.IAdapter1,
	device:              ^dx.IDevice,
	queue:               ^dx.ICommandQueue,
	swapchain:           ^dxgi.ISwapChain3,
	rtv_descriptor_heap: ^dx.IDescriptorHeap,
	frame_index:         u32,
	render_targets:      [NUM_RENDERTARGETS]^dx.IResource,
}

@(private)
state: ^State

init :: proc(window: ^sdl.Window) -> bool {
	log.info("Triangle init")
	state = new(State)

	hr: dx.HRESULT

	// Init debug controller
	when ODIN_DEBUG {
		hr = dx.GetDebugInterface(dx.IDebug_UUID, (^rawptr)(&state.debug_ctrl))
		check(hr, "Failed to create debug controller") or_return
		state.debug_ctrl->EnableDebugLayer()
		log.debug("D3D12 debug layer enabled")
	}

	// Init dxgi factory
	{
		flags: dxgi.CREATE_FACTORY
		when ODIN_DEBUG {flags += {.DEBUG}}

		hr = dxgi.CreateDXGIFactory2(flags, dxgi.IFactory4_UUID, cast(^rawptr)&state.factory)
		check(hr, "Failed to create factory") or_return
	}

	// Naive adapter selection
	err_not_found :: dxgi.HRESULT(-142213123)
	for i: u32 = 0; state.factory->EnumAdapters1(i, &state.adapter) != err_not_found; {
		desc: dxgi.ADAPTER_DESC1
		state.adapter->GetDesc1(&desc)
		if desc.Flags & dxgi.ADAPTER_FLAG.SOFTWARE != dxgi.ADAPTER_FLAG(0) do continue
		if dx.CreateDevice(state.adapter, ._12_0, dxgi.IDevice_UUID, nil) >= 0 do break
	}

	if state.adapter == nil {
		log.error("Could not find hardware adapter")
		return false
	}

	// Create D3D12 device
	hr = dx.CreateDevice(
		(^dxgi.IUnknown)(state.adapter),
		._12_0,
		dx.IDevice_UUID,
		(^rawptr)(&state.device),
	)
	check(hr, "Failed to create device") or_return

	// Create command queue
	hr =
	state.device->CreateCommandQueue(
		&dx.COMMAND_QUEUE_DESC{Type = .DIRECT},
		dx.ICommandQueue_UUID,
		(^rawptr)(&state.queue),
	)
	check(hr, "Failed to create command queue") or_return

	// Swapchain creation
	{
		width, height := expand_values(client_size_from_window(window))
		desc := dxgi.SWAP_CHAIN_DESC1 {
			Width = u32(width),
			Height = u32(height),
			Format = .R8G8B8A8_UNORM,
			SampleDesc = {Count = 1, Quality = 0},
			BufferUsage = {.RENDER_TARGET_OUTPUT},
			BufferCount = NUM_RENDERTARGETS,
			SwapEffect = .FLIP_DISCARD,
			AlphaMode = .UNSPECIFIED,
		}

		hr =
		state.factory->CreateSwapChainForHwnd(
			(^dxgi.IUnknown)(state.queue),
			hwnd_from_window(window),
			&desc,
			nil,
			nil,
			(^^dxgi.ISwapChain1)(&state.swapchain),
		)
		check(hr, "Failed to create swapchain") or_return
	}

	state.frame_index = state.swapchain->GetCurrentBackBufferIndex()

	// Descriptor heap
	{
		desc := dx.DESCRIPTOR_HEAP_DESC {
			NumDescriptors = NUM_RENDERTARGETS,
			Type           = .RTV,
			Flags          = {},
		}

		hr =
		state.device->CreateDescriptorHeap(
			&desc,
			dx.IDescriptorHeap_UUID,
			(^rawptr)(&state.rtv_descriptor_heap),
		)
		check(hr, "Failed creating descriptor heap")
	}

	// Fetch rendertargets from swapchain

	return true
}

deinit :: proc() {
	log.info("Triangle deinit")
	free(state)
}

update :: proc(window: ^sdl.Window) {
	// log.info("Updating")
}

check :: proc(res: dx.HRESULT, message: string) -> bool {
	if (res >= 0) do return true
	log.errorf("%v. Error code: %0x\n", message, u32(res))
	return false
}

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


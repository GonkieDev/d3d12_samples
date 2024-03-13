package triangle

// Credits to: https://gist.github.com/jakubtomsu/ecd83e61976d974c7730f9d7ad3e1fd0
// This file is based on ^

// Renders simple triangle
// NOTE(gsp): window resizing not implemented

import "core:log"
import "core:mem"
import win32 "core:sys/windows"
import dx "vendor:directx/d3d12"
import d3d_compiler "vendor:directx/d3d_compiler"
import dxgi "vendor:directx/dxgi"
import sdl "vendor:sdl2"

import utils "../utils"
check :: utils.check

@(private)
NUM_RENDERTARGETS :: 2

State :: struct {
	debug_ctrl:                 ^dx.IDebug,
	factory:                    ^dxgi.IFactory4,
	adapter:                    ^dxgi.IAdapter1,
	device:                     ^dx.IDevice,
	msg_callback_cookie:        u32,
	queue:                      ^dx.ICommandQueue,
	swapchain:                  ^dxgi.ISwapChain3,
	rtv_descriptor_heap:        ^dx.IDescriptorHeap,
	frame_index:                u32,
	render_targets:             [NUM_RENDERTARGETS]^dx.IResource,
	command_allocator:          ^dx.ICommandAllocator,
	root_signature:             ^dx.IRootSignature,
	pipeline:                   ^dx.IPipelineState,
	command_list:               ^dx.IGraphicsCommandList,
	vertex_buffer:              ^dx.IResource,
	vertex_buffer_view:         dx.VERTEX_BUFFER_VIEW,
	frame_finished_fence:       ^dx.IFence,
	frame_finished_fence_value: u64,
	frame_finished_fence_event: win32.HANDLE,
}

@(private)
state: ^State

init :: proc(window: ^sdl.Window) -> bool {

	log.info("Triangle init")
	state = new(State)

	hr: dx.HRESULT

	// Init debug controller
	when ODIN_DEBUG {
		state.debug_ctrl = utils.enable_debug_layer({}) or_return
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

	// Register callback message fn
	state.msg_callback_cookie = utils.register_debug_message_callback(state.device, utils.default_message_callback) or_return

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
		width, height := expand_values(utils.client_size_from_window(window))
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
			utils.hwnd_from_window(window),
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
			Type           = .RTV, // render target view
			Flags          = {},
		}

		hr =
		state.device->CreateDescriptorHeap(
			&desc,
			dx.IDescriptorHeap_UUID,
			(^rawptr)(&state.rtv_descriptor_heap),
		)
		check(hr, "Failed creating descriptor heap") or_return
	}

	// Fetch rendertargets from swapchain
	{
		rtv_descriptor_size: u32 = state.device->GetDescriptorHandleIncrementSize(.RTV)
		rtv_descriptor_handle: dx.CPU_DESCRIPTOR_HANDLE
		state.rtv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&rtv_descriptor_handle)
		for i: u32 = 0; i < NUM_RENDERTARGETS; i += 1 {
			hr = state.swapchain->GetBuffer(i, dx.IResource_UUID, (^rawptr)(&state.render_targets[i]))
			check(hr, "Failed obtaining render target") or_return
			state.device->CreateRenderTargetView(state.render_targets[i], nil, rtv_descriptor_handle)
			rtv_descriptor_handle.ptr += uint(rtv_descriptor_size)
		}
	}

	// Command allocator
	hr =
	state.device->CreateCommandAllocator(
		.DIRECT,
		dx.ICommandAllocator_UUID,
		(^rawptr)(&state.command_allocator),
	)
	check(hr, "Failed to create command allocator") or_return

	// Root sig
	{
		serialized_desc: ^dx.IBlob
		{ 	// Create serialized desc
			desc := dx.VERSIONED_ROOT_SIGNATURE_DESC {
				Version = ._1_0,
			}
			desc.Desc_1_0.Flags = {.ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT}
			hr = dx.SerializeVersionedRootSignature(&desc, &serialized_desc, nil)
			check(hr, "Failed to serialized root signature") or_return
		}

		hr =
		state.device->CreateRootSignature(
			0,
			serialized_desc->GetBufferPointer(),
			serialized_desc->GetBufferSize(),
			dx.IRootSignature_UUID,
			(^rawptr)(&state.root_signature),
		)
		check(hr, "Failed creating root signature") or_return
		serialized_desc->Release()
	}

	// Pipeline creation
	{
		shader_source: cstring = g_shader_source
		shader_source_size: uint = len(shader_source)

		compile_flags: u32 = 0
		when ODIN_DEBUG {
			compile_flags |= u32(d3d_compiler.D3DCOMPILE.DEBUG)
			compile_flags |= u32(d3d_compiler.D3DCOMPILE.SKIP_OPTIMIZATION)
		}

		vs: ^dx.IBlob = nil
		ps: ^dx.IBlob = nil

		hr = d3d_compiler.Compile(
			rawptr(shader_source),
			shader_source_size,
			nil,
			nil,
			nil,
			"VSMain",
			"vs_4_0",
			compile_flags,
			0,
			&vs,
			nil,
		)
		check(hr, "Failed to compile vertex shader") or_return

		hr = d3d_compiler.Compile(
			rawptr(shader_source),
			shader_source_size,
			nil,
			nil,
			nil,
			"PSMain",
			"ps_4_0",
			compile_flags,
			0,
			&ps,
			nil,
		)
		check(hr, "Failed to compile pixel shader") or_return

		vertex_format := []dx.INPUT_ELEMENT_DESC {
			{SemanticName = "POSITION", Format = .R32G32B32_FLOAT, InputSlotClass = .PER_VERTEX_DATA},
			 {
				SemanticName = "COLOR",
				Format = .R32G32B32A32_FLOAT,
				InputSlotClass = .PER_VERTEX_DATA,
				AlignedByteOffset = size_of(f32) * 3,
			},
		}

		blend_state := dx.RENDER_TARGET_BLEND_DESC {
			BlendEnable           = false,
			LogicOpEnable         = false,
			SrcBlend              = .ONE,
			DestBlend             = .ZERO,
			BlendOp               = .ADD,
			SrcBlendAlpha         = .ONE,
			DestBlendAlpha        = .ZERO,
			BlendOpAlpha          = .ADD,
			LogicOp               = .NOOP,
			RenderTargetWriteMask = u8(dx.COLOR_WRITE_ENABLE_ALL),
		}

		pipeline_state_desc := dx.GRAPHICS_PIPELINE_STATE_DESC {
			pRootSignature = state.root_signature,
			VS = {pShaderBytecode = vs->GetBufferPointer(), BytecodeLength = vs->GetBufferSize()},
			PS = {pShaderBytecode = ps->GetBufferPointer(), BytecodeLength = ps->GetBufferSize()},
			StreamOutput = {},
			BlendState =  {
				AlphaToCoverageEnable = false,
				IndependentBlendEnable = false,
				RenderTarget = {0 = blend_state, 1 ..< 7 = {}},
			},
			SampleMask = 0xFFFFFFFF,
			RasterizerState =  {
				FillMode = .SOLID,
				CullMode = .BACK,
				FrontCounterClockwise = false,
				DepthBias = 0,
				DepthBiasClamp = 0,
				SlopeScaledDepthBias = 0,
				DepthClipEnable = true,
				MultisampleEnable = false,
				AntialiasedLineEnable = false,
				ForcedSampleCount = 0,
				ConservativeRaster = .OFF,
			},
			DepthStencilState = {DepthEnable = false, StencilEnable = false},
			InputLayout = {pInputElementDescs = &vertex_format[0], NumElements = u32(len(vertex_format))},
			PrimitiveTopologyType = .TRIANGLE,
			NumRenderTargets = 1,
			RTVFormats = {0 = .R8G8B8A8_UNORM, 1 ..< 7 = .UNKNOWN},
			DSVFormat = .UNKNOWN,
			SampleDesc = {Count = 1, Quality = 0},
		}

		hr =
		state.device->CreateGraphicsPipelineState(
			&pipeline_state_desc,
			dx.IPipelineState_UUID,
			(^rawptr)(&state.pipeline),
		)
		check(hr, "Failed to create pipeline") or_return

		vs->Release()
		ps->Release()

	} // end of pipeline creation

	// Command list
	hr =
	state.device->CreateCommandList(
		0,
		.DIRECT,
		state.command_allocator,
		state.pipeline,
		dx.ICommandList_UUID,
		(^rawptr)(&state.command_list),
	)
	check(hr, "Failed to create command list") or_return

	hr = state.command_list->Close()
	check(hr, "Failed to close command list") or_return

	// Vertex buffer
	{
		Vertex :: struct {
			pos:   [3]f32,
			color: [4]f32,
		}
		vertices := [?]Vertex {
			{pos = {0.0, 0.5, 0.0}, color = {1, 0, 0, 1}},
			{pos = {0.5, -0.5, 0.0}, color = {0, 1, 0, 1}},
			{pos = {-0.5, -0.5, 0.0}, color = {0, 0, 1, 1}},
		}

		heap_props := dx.HEAP_PROPERTIES {
			Type = .UPLOAD,
		}
		vertex_buffer_size := len(vertices) * size_of(vertices[0])

		resource_desc := dx.RESOURCE_DESC {
			Dimension = .BUFFER,
			Alignment = 0,
			Width = u64(vertex_buffer_size),
			Height = 1,
			DepthOrArraySize = 1,
			MipLevels = 1,
			Format = .UNKNOWN,
			SampleDesc = {Count = 1, Quality = 0},
			Layout = .ROW_MAJOR,
			Flags = {},
		}

		hr =
		state.device->CreateCommittedResource(
			&heap_props,
			{},
			&resource_desc,
			dx.RESOURCE_STATE_GENERIC_READ,
			nil,
			dx.IResource_UUID,
			(^rawptr)(&state.vertex_buffer),
		)
		check(hr, "Failed to create vertex buffer") or_return

		gpu_data: rawptr
		read_range: dx.RANGE
		hr = state.vertex_buffer->Map(0, &read_range, &gpu_data)
		check(hr, "Failed to map gpu memory for vertex buffer") or_return
		mem.copy(gpu_data, &vertices[0], vertex_buffer_size)
		state.vertex_buffer->Unmap(0, nil)

		state.vertex_buffer_view = dx.VERTEX_BUFFER_VIEW {
			BufferLocation = state.vertex_buffer->GetGPUVirtualAddress(),
			StrideInBytes  = u32(size_of(Vertex)),
			SizeInBytes    = u32(vertex_buffer_size),
		}

	}

	// Frame finished fence
	{
		hr =
		state.device->CreateFence(
			state.frame_finished_fence_value,
			{},
			dx.IFence_UUID,
			(^rawptr)(&state.frame_finished_fence),
		)
		check(hr, "Failed to create frame finished fence") or_return
		state.frame_finished_fence_value += 1
		state.frame_finished_fence_event = win32.CreateEventW(nil, false, false, nil)
		if state.frame_finished_fence_event == nil {
			log.fatal("Failed to create fence event")
			return false
		}
	}

	return true
}

deinit :: proc() {
	log.info("Triangle deinit")

	using state

	wait_for_previous_frame()
	win32.CloseHandle(frame_finished_fence_event)

	factory->Release()
	
	utils.unregister_debug_message_callback(device, msg_callback_cookie)

	free(state)
}

update :: proc(window: ^sdl.Window) -> bool {
	// log.info("Updating")

	using state

	hr: dx.HRESULT

	hr = command_allocator->Reset()
	check(hr, "Failed resetting command allocator") or_return

	hr = command_list->Reset(command_allocator, pipeline)
	check(hr, "Failed to reset command list") or_return

	width, height := expand_values(utils.client_size_from_window(window))
	viewport := dx.VIEWPORT {
		Width  = f32(width),
		Height = f32(height),
	}
	scissor_rect := dx.RECT {
		right  = width,
		bottom = height,
	}

	command_list->SetGraphicsRootSignature(root_signature)
	command_list->RSSetViewports(1, &viewport)
	command_list->RSSetScissorRects(1, &scissor_rect)

	to_render_target_barrier := dx.RESOURCE_BARRIER {
		Type = .TRANSITION,
		Flags = {},
		Transition =  {
			pResource = render_targets[frame_index],
			StateBefore = dx.RESOURCE_STATE_PRESENT,
			StateAfter = {.RENDER_TARGET},
			Subresource = dx.RESOURCE_BARRIER_ALL_SUBRESOURCES,
		},
	}
	command_list->ResourceBarrier(1, &to_render_target_barrier)

	// TODO(gsp): make this look more like d3d12 cpp triangle sample
	rtv_handle: dx.CPU_DESCRIPTOR_HANDLE
	rtv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&rtv_handle)
	if (frame_index > 0) {
		size := device->GetDescriptorHandleIncrementSize(.RTV)
		rtv_handle.ptr += uint(frame_index * size)
	}

	command_list->OMSetRenderTargets(1, &rtv_handle, false, nil)

	// Record commands

	// Clear
	clear_color: [4]f32 = {0.3, 0.3, 0.3, 1.0}
	command_list->ClearRenderTargetView(rtv_handle, &clear_color, 0, nil)

	// Draw
	command_list->IASetPrimitiveTopology(.TRIANGLELIST)
	command_list->IASetVertexBuffers(0, 1, &vertex_buffer_view)
	command_list->DrawInstanced(3, 1, 0, 0)

	// Indicate that backbuffer will not be used to present
	to_present_barrier := to_render_target_barrier
	to_present_barrier.Transition.StateBefore = {.RENDER_TARGET}
	to_present_barrier.Transition.StateAfter = dx.RESOURCE_STATE_PRESENT
	command_list->ResourceBarrier(1, &to_present_barrier)

	hr = command_list->Close()
	check(hr, "Failed to close command list") or_return

	// Execute command list
	{
		command_lists := [?]^dx.IGraphicsCommandList{command_list}
		queue->ExecuteCommandLists(len(command_lists), (^^dx.ICommandList)(&command_lists[0]))
	}

	// Present
	hr = swapchain->Present1(1, {}, &{})
	check(hr, "Failed to present") or_return

	wait_for_previous_frame() or_return

	return true
}

wait_for_previous_frame :: proc() -> bool {
	// WAITING FOR THE FRAME TO COMPLETE BEFORE CONTINUING IS NOT BEST PRACTICE.

	using state

	hr: dx.HRESULT

	current_fence_value := frame_finished_fence_value
	hr = queue->Signal(frame_finished_fence, current_fence_value)
	check(hr, "Failed to signal fence") or_return

	frame_finished_fence_value += 1
	completed := frame_finished_fence->GetCompletedValue()

	if completed < current_fence_value {
		hr = frame_finished_fence->SetEventOnCompletion(current_fence_value, frame_finished_fence_event)
		check(hr, "Failed to set event on completion flag") or_return
		win32.WaitForSingleObject(frame_finished_fence_event, win32.INFINITE)
	}

	frame_index = swapchain->GetCurrentBackBufferIndex()
	return true
}

// Shader source code
g_shader_source: cstring : `
struct PSInput {
	float4 position: SV_POSITION;
	float4 color: COLOR;
};

PSInput VSMain(float4 position: POSITION0, float4 color: COLOR0) {
	PSInput result;
	result.position = position;
	result.color = color;
	return result;
}

float4 PSMain(PSInput input) : SV_TARGET {
	return input.color;
};
`


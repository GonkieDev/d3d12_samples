package main

import "core:log"
import dxgi "vendor:directx/dxgi"
import sdl "vendor:sdl2"

import "triangle"

main :: proc() {
	context.logger = log.create_console_logger()

	if err := sdl.Init({.VIDEO}); err != 0 {
		log.fatal("Failed to create window")
		return
	}
	defer sdl.Quit()

	window_title := "D3D12 Samples" + " (DEBUG)" when ODIN_DEBUG else ""
	window_width := i32(640)
	window_height := i32(640)
	window := sdl.CreateWindow(
		"D3D12 Samples",
		sdl.WINDOWPOS_UNDEFINED,
		sdl.WINDOWPOS_UNDEFINED,
		window_width,
		window_height,
		{.ALLOW_HIGHDPI, .SHOWN, .RESIZABLE},
	)
	if window == nil {
		log.fatal("Failed to create SDL window. Err code:", sdl.GetError())
		return
	}
	defer sdl.DestroyWindow(window)

	if !triangle.init(window) do return
	defer triangle.deinit()

	main_loop: for {
		for event: sdl.Event; sdl.PollEvent(&event); {
			#partial switch event.type {
			case .QUIT:
				break main_loop
			}

			triangle.update(window)
		}
	}

}

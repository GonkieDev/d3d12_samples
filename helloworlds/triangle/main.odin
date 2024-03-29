package main

import "core:log"
import dxgi "vendor:directx/dxgi"
import sdl "vendor:sdl2"

main :: proc() {
	context.logger = log.create_console_logger()

	if err := sdl.Init({.VIDEO}); err != 0 {
		log.fatal("Failed to init SDL")
		return
	}
	defer sdl.Quit()

	window_title := "D3D12 Samples" + " (DEBUG)" when ODIN_DEBUG else ""
	window_width := i32(720)
	window_height := i32(480)
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

	if !r_init(window) do return

	main_loop: for {
		for event: sdl.Event; sdl.PollEvent(&event); {
			#partial switch event.type {
			case .QUIT:
				break main_loop				
			}

			r_update(window)
		}
	}

}

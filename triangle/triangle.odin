package triangle

import "core:log"
import sdl "vendor:sdl2"

init  :: proc(window: ^sdl.Window) {
	log.info("Triangle init")
}

deinit :: proc() {
	log.info("Triangle deinit")
}

update :: proc(window: ^sdl.Window) {
	log.info("Updating")	
}



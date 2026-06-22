package main

import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:unicode"

main :: proc() {
	term_options: posix.termios
	if rc := posix.tcgetattr(posix.STDIN_FILENO, &term_options); rc == .FAIL {
		panic("Couldn't get terminal flags")
	}
	defer {
		if rc := posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, &term_options); rc == .FAIL {
			panic("Couldn't reset terminal flags. Consider restarting your terminal")
		}
	}

	enable_raw_mode(term_options)

	buf: [1]u8
	for {
		buf[0] = 0
		_, err := os.read(os.stdin, buf[:])
		if err != nil && err != .EAGAIN && err != .EOF {
			fmt.printf("failed to read: %v\r\n", err)
			panic("Exit")
		}
		c := buf[0]

		if unicode.is_control(rune(c)) {
			fmt.printf("%d\r\n", c)
		} else {
			fmt.printf("%d ('%c')\r\n", c, c)
		}

		if c == 'q' {
			break
		}
	}
}

enable_raw_mode :: proc(termios: posix.termios) {
	termios := termios

	termios.c_iflag -= {.BRKINT, .ICRNL, .INPCK, .ISTRIP, .IXON}
	termios.c_oflag -= {.OPOST}
	termios.c_cflag += {.CS8}
	termios.c_lflag -= {.ECHO, .ICANON, .IEXTEN, .ISIG}

	// Read can read 0 bytes
	termios.c_cc[.VMIN] = 0
	// Read will wait up to 1/10sec before returning
	termios.c_cc[.VTIME] = 1

	if posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, &termios) == .FAIL {
		panic("Failed to enable raw mode")
	}
}


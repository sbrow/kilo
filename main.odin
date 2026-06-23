package main

import "core:c/libc"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:terminal/ansi"

WELCOME :: "Kilo editor -- version " + VERSION

VERSION :: "0.0.1"

Editor_Config :: struct {
	cx, cy:       int,
	screen_rows:  int,
	screen_cols:  int,
	orig_termios: posix.termios,
}

Win_Size :: struct {
	ws_row:    u16,
	ws_col:    u16,
	ws_xpixel: u16,
	ws_ypixel: u16,
}

Editor_Key :: enum {
	Arrow_Up = 1000,
	Arrow_Down,
	Arrow_Left,
	Arrow_Right,
	Home,
	End,
	Page_Up,
	Page_Down,
	Delete,
}

main :: proc() {
	b: strings.Builder
	strings.builder_init_len(&b, mem.DEFAULT_PAGE_SIZE, context.temp_allocator)

	e: Editor_Config
	if rc := posix.tcgetattr(posix.STDIN_FILENO, &e.orig_termios); rc == .FAIL {
		panic("Couldn't get terminal flags")
	}
	defer cleanup(&b, &e.orig_termios)

	enable_raw_mode(e.orig_termios)
	init_editor(&e)

	for {
		defer free_all(context.temp_allocator)

		editor_refresh_screen(&b, e)

		if exit := editor_process_keypress(&b, &e); exit {
			break
		}
	}
}

cleanup :: proc(b: ^strings.Builder, options: ^posix.termios) {
	if rc := posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, options); rc == .FAIL {
		panic("Couldn't reset terminal flags. Consider restarting your terminal")
	}

	// Clear the display, then move the cursor to 0, 0
	fmt.sbprint(b, (ansi.CSI + "2" + ansi.ED) + (ansi.CSI + ansi.CUP))

	os.write(os.stdout, b.buf[:]) // TODO: Handle err
	strings.builder_reset(b)

	// TODO: Is this necessary?
	// delete(context.temp_allocator)
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

init_editor :: proc(e: ^Editor_Config) {
	rows, cols, ok := get_window_size()
	if !ok {
		panic("Failed to get window size")
	}

	e.screen_rows = rows
	e.screen_cols = cols
}

get_window_size :: proc() -> (rows, cols: int, ok: bool) {
	ws: Win_Size

	if linux.ioctl(posix.STDOUT_FILENO, linux.TIOCGWINSZ, uintptr(&ws)) == 0 {
		cols = int(ws.ws_col)
		rows = int(ws.ws_row)
		ok = cols != 0
	} else {
		// Move cursor to MAX, MAX
		n, err := os.write(
			os.stdout,
			transmute([]u8)string(ansi.CSI + "999" + ansi.CUF + ansi.CSI + "999" + ansi.CUD),
		)

		if n == 12 && err == nil {
			return get_cursor_position()
		}
	}

	return
}

get_cursor_position :: proc() -> (rows, cols: int, ok: bool) {
	n, err := os.write(os.stdout, transmute([]u8)string(ansi.CSI + ansi.DSR))
	if n == 4 && err == nil {
		buf: [32]u8

		for i := 0; i < len(buf) - 1; i += 1 {
			n, err = os.read(os.stdin, buf[i:i + 1])
			if n != 1 || buf[i] == 'R' {
				buf[i] = 0
				break
			}
		}

		if string(buf[0:2]) == ansi.CSI {
			ok = libc.sscanf(cstring(&buf[2]), "%d;%d", &rows, &cols) == 2
		}
	}

	return
}

// TODO: Confusing that refresh screen draws an clear screen doesn't?
editor_refresh_screen :: proc(b: ^strings.Builder, e: Editor_Config) {
	defer strings.builder_reset(b)
	defer os.write(os.stdout, b.buf[:]) // TODO: Handle err

	// Hide the cursor
	// Move the cursor to 0, 0
	fmt.sbprint(b, string((ansi.CSI + ansi.DECTCEM_HIDE) + (ansi.CSI + ansi.CUP)))

	editor_draw_rows(b, e)

	// Move the cursor, then display it
	fmt.sbprintf(
		b,
		"%s%d;%d%s",
		ansi.CSI,
		e.cy + 1,
		e.cx + 1,
		ansi.CUP + (ansi.CSI + ansi.DECTCEM_SHOW),
	)
}

editor_draw_rows :: proc(b: ^strings.Builder, e: Editor_Config) {
	for y in 0 ..< e.screen_rows - 1 {
		if y == e.screen_rows / 3 {
			welcome := WELCOME
			if len(WELCOME) > e.screen_cols {
				welcome = welcome[:e.screen_cols]
			}

			padding := (e.screen_cols - len(welcome)) / 2
			if (padding > 0) {
				fmt.sbprint(b, "~")
				padding -= 1
			}
			for _ in 0 ..< padding {
				fmt.sbprint(b, " ")
			}

			fmt.sbprint(b, welcome, ansi.CSI + ansi.EL + "\r\n")
		} else {
			fmt.sbprint(b, "~" + ansi.CSI + ansi.EL + "\r\n")
		}
	}
	fmt.sbprint(b, "~" + ansi.CSI + ansi.EL)
}

editor_process_keypress :: proc(b: ^strings.Builder, e: ^Editor_Config) -> (exit: bool) {
	c := editor_read_key()
	switch (c) {
	// Quit
	case int(ctrl_key('q')):
		return true
	case 'h', 'j', 'k', 'l', int(Editor_Key.Arrow_Up) ..= int(Editor_Key.Page_Down):
		editor_move_cursor(e, c)
	}

	return false
}

editor_read_key :: proc() -> int {
	buf: [4]u8

	for {
		n, err := os.read(os.stdin, buf[0:1])
		if n == 1 {
			break
		}
		if n == -1 && !(err == .EAGAIN || err == .EOF) {
			panic("failed to read")
		}
	}

	if buf[0] == '\e' {
		n, err := os.read(os.stdin, buf[1:2])
		if n != 1 {
			return int(buf[0])
		}

		n, err = os.read(os.stdin, buf[2:3])
		if n != 1 {
			return int(buf[0])
		}

		if string(buf[0:2]) == ansi.CSI {
			if buf[2] >= '0' && buf[2] <= '9' {
				n, err = os.read(os.stdin, buf[3:4])
				if n != 1 {
					return int(buf[0])
				}

				if buf[3] == '~' {
					switch (buf[2]) {
					case '1', '7':
						return int(Editor_Key.Home)
					case '3':
						return int(Editor_Key.Delete)
					case '4', '8':
						return int(Editor_Key.End)
					case '5':
						return int(Editor_Key.Page_Up)
					case '6':
						return int(Editor_Key.Page_Down)
					}
				}
			} else {
				switch (buf[2]) {
				case 'A':
					return int(Editor_Key.Arrow_Up)
				case 'B':
					return int(Editor_Key.Arrow_Down)
				case 'C':
					return int(Editor_Key.Arrow_Right)
				case 'D':
					return int(Editor_Key.Arrow_Left)
				case 'H':
					return int(Editor_Key.Home)
				case 'F':
					return int(Editor_Key.End)
				case:
					return int(buf[0])
				}
			}
		} else if string(buf[0:2]) == "\eO" {
			switch (buf[2]) {
			case 'H':
				return int(Editor_Key.Home)
			case 'F':
				return int(Editor_Key.End)
			}
		}
	}

	return int(buf[0])
}

editor_move_cursor :: proc(e: ^Editor_Config, key: int) {
	switch (key) {
	case int(Editor_Key.Arrow_Up):
		fallthrough
	case 'k':
		e.cy = max(0, e.cy - 1)
	case int(Editor_Key.Arrow_Down):
		fallthrough
	case 'j':
		e.cy = min(e.screen_rows - 1, e.cy + 1)
	case int(Editor_Key.Arrow_Left):
		fallthrough
	case 'h':
		e.cx = max(0, e.cx - 1)
	case int(Editor_Key.Arrow_Right):
		fallthrough
	case 'l':
		e.cx = min(e.screen_cols - 1, e.cx + 1)

	case int(Editor_Key.Home):
		e.cx = 0
	case int(Editor_Key.End):
		e.cx = e.screen_cols - 1
	case int(Editor_Key.Page_Up):
		e.cy = 0
	case int(Editor_Key.Page_Down):
		e.cy = e.screen_rows - 1
	}
}

ctrl_key :: proc(r: u8) -> u8 {
	return r & 0x1f
}


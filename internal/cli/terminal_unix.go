//go:build unix

package cli

import (
	"os"
	"syscall"
	"unsafe"
)

// terminalWidth is the column count of the terminal f is attached to, or 0
// if it isn't a terminal.
func terminalWidth(f *os.File) int {
	var size struct{ rows, cols, xpixel, ypixel uint16 }
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), uintptr(syscall.TIOCGWINSZ), uintptr(unsafe.Pointer(&size)))
	if errno != 0 {
		return 0
	}
	return int(size.cols)
}

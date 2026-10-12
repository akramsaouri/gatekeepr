//go:build !unix

package cli

import "os"

func terminalWidth(*os.File) int { return 0 }

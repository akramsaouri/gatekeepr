// Command gatekeepr shows when your Appgate SDP session on macOS expires,
// worked out from Appgate's driver logs. Unofficial and not affiliated with
// Appgate.
package main

import (
	"os"

	"github.com/akramsaouri/gatekeepr/internal/cli"
)

func main() {
	os.Exit(cli.Run(os.Args[1:], cli.System()))
}

// Command pictunnel is the PicTunnel server. Serving arrives in sub-project 2.
package main

import (
	"fmt"
	"io"
	"os"
)

// version is set at build time with -ldflags "-X main.version=<version>".
var version = "dev"

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 1 && (args[0] == "version" || args[0] == "--version") {
		fmt.Fprintf(stdout, "pictunnel %s\n", version)
		return 0
	}
	fmt.Fprintln(stderr, "usage: pictunnel version")
	return 2
}

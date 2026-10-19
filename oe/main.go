// Command oe is the deterministic engine behind the orchestrate-epic skill.
package main

import (
	"os"

	"github.com/maro114510/skills/oe/cmd"
	"github.com/maro114510/skills/oe/internal/runner"
)

// version is set at build time with -ldflags "-X main.version=<version>".
var version = "v0.0.0-dev"

func main() {
	os.Exit(cmd.Main(os.Args[1:], cmd.Env{
		Stdout:  os.Stdout,
		Stderr:  os.Stderr,
		Exec:    runner.Exec{},
		Version: version,
	}))
}

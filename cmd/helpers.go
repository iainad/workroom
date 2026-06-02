package cmd

import (
	"os"

	"github.com/joelmoss/workroom/internal/config"
)

func getCwd() (string, error) {
	return os.Getwd()
}

// resolveProject returns the project directory for a command: the canonicalized
// --project value when set (so the desktop app passes an explicit path rather than
// relying on a .app's working directory), otherwise the current working directory.
func resolveProject(flag string) (string, error) {
	if flag != "" {
		return config.CanonicalPath(flag)
	}
	return getCwd()
}

package cmd

import (
	"fmt"
	"os"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/vcs"
	"github.com/spf13/cobra"
)

// addProjectCmd is an internal, app-only command: it registers an empty project
// (one with no workrooms yet) so the macOS app's sidebar can show it. The human
// CLI never needs it — `create` auto-registers a project on first use, and the
// human `list` only shows projects that have workrooms — so it is hidden and
// available solely in --json mode, which is how the app invokes it.
var addProjectCmd = &cobra.Command{
	Use:    "add-project [PATH]",
	Short:  "Register a project (internal; used by the macOS app via --json)",
	Hidden: true,
	Args:   cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		currentCommand = "add-project"
		if !jsonOutput {
			return fmt.Errorf("add-project is only available in --json mode")
		}
		svc, err := newService()
		if err != nil {
			return err
		}
		if len(args) != 1 {
			return fmt.Errorf("a path argument is required")
		}

		canon, err := config.CanonicalPath(args[0])
		if err != nil {
			return err
		}
		v, err := vcs.Detect(canon) // rejects non-VCS directories with ErrUnsupportedVCS
		if err != nil {
			return err
		}
		vcsType := string(v.Type())
		if err := svc.Config.AddProject(canon, vcsType); err != nil {
			return err
		}

		return writeJSONSuccess(os.Stdout, "add-project", map[string]any{
			"path": canon, "vcs": vcsType,
		})
	},
}

func init() {
	rootCmd.AddCommand(addProjectCmd)
}

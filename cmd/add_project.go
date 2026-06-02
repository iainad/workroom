package cmd

import (
	"fmt"
	"os"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/vcs"
	"github.com/spf13/cobra"
)

var addProjectCmd = &cobra.Command{
	Use:     "add-project [PATH]",
	Aliases: []string{"add"},
	Short:   "Register a project so its workrooms can be managed",
	Long:    "Register a project directory (a Git repo or JJ workspace) so it appears as a managed project, even before it has any workrooms. Defaults to the current directory.",
	Args:    cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		currentCommand = "add-project"
		svc, err := newService()
		if err != nil {
			return err
		}

		var path string
		if len(args) == 1 {
			path = args[0]
		} else {
			if jsonOutput {
				return fmt.Errorf("a path argument is required in --json mode")
			}
			path, err = getCwd()
			if err != nil {
				return err
			}
		}

		canon, err := config.CanonicalPath(path)
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

		if jsonOutput {
			return writeJSONSuccess(os.Stdout, "add-project", map[string]any{
				"path": canon, "vcs": vcsType,
			})
		}
		fmt.Printf("Project '%s' added (%s).\n", canon, v.Label())
		return nil
	},
}

func init() {
	rootCmd.AddCommand(addProjectCmd)
}

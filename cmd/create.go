package cmd

import (
	"os"

	"github.com/spf13/cobra"
)

var (
	createProject  string
	createNoEditor bool
)

var createCmd = &cobra.Command{
	Use:     "create",
	Aliases: []string{"c"},
	Short:   "Create a new workroom",
	Long:    "Create a new workroom at the same level as your main project directory, using JJ workspaces if available, otherwise falling back to git worktrees. A random friendly name is auto-generated.",
	Args:    cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		currentCommand = "create"
		svc, err := newService()
		if err != nil {
			return err
		}
		dir, err := resolveProject(createProject)
		if err != nil {
			return err
		}
		if createNoEditor {
			svc.SuppressEditor = true
		}

		if jsonOutput {
			res, err := svc.CreateNamed(dir)
			if err != nil {
				// Create is not transactional: on setup failure the workroom already
				// exists, so report it so the GUI can offer to delete it.
				if res.Name != "" {
					jsonErrorExtra = map[string]any{"created": map[string]any{
						"name": res.Name, "path": res.Path, "vcs": res.VCS, "project": res.Project,
					}}
				}
				return err
			}
			return writeJSONSuccess(os.Stdout, "create", map[string]any{
				"name": res.Name, "path": res.Path, "vcs": res.VCS, "project": res.Project,
			})
		}

		return svc.Create(dir)
	},
}

func init() {
	createCmd.Flags().StringVar(&createProject, "project", "", "Project directory to create the workroom in (defaults to the current directory)")
	createCmd.Flags().BoolVar(&createNoEditor, "no-editor", false, "Do not offer to open the new workroom in $EDITOR")
	rootCmd.AddCommand(createCmd)
}

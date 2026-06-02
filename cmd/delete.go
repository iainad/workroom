package cmd

import (
	"fmt"
	"os"

	"github.com/joelmoss/workroom/internal/errs"
	"github.com/spf13/cobra"
)

var (
	confirmFlag   string
	deleteProject string
)

var deleteCmd = &cobra.Command{
	Use:     "delete [NAME]",
	Aliases: []string{"d"},
	Short:   "Delete an existing workroom",
	Long:    "Delete an existing workroom. When run without a name, shows an interactive multi-select menu.",
	Args:    cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		currentCommand = "delete"
		svc, err := newService()
		if err != nil {
			return err
		}
		dir, err := resolveProject(deleteProject)
		if err != nil {
			return err
		}

		if jsonOutput {
			if len(args) == 0 {
				return fmt.Errorf("%w: a workroom name is required in --json mode (interactive delete is unavailable)", errs.ErrInvalidName)
			}
			name := args[0]
			if confirmFlag == "" {
				return fmt.Errorf("%w: --confirm <name> is required in --json mode", errs.ErrConfirmMismatch)
			}
			if err := svc.Delete(dir, name, confirmFlag); err != nil {
				return err
			}
			return writeJSONSuccess(os.Stdout, "delete", map[string]any{"name": name})
		}

		if len(args) == 0 {
			return svc.InteractiveDelete(dir)
		}
		return svc.Delete(dir, args[0], confirmFlag)
	},
}

func init() {
	deleteCmd.Flags().StringVar(&confirmFlag, "confirm", "", "Skip confirmation if value matches the workroom name (required in --json mode)")
	deleteCmd.Flags().StringVar(&deleteProject, "project", "", "Project directory the workroom belongs to (defaults to the current directory)")
	rootCmd.AddCommand(deleteCmd)
}

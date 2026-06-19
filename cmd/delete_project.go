package cmd

import (
	"fmt"
	"io"
	"os"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/errs"
	"github.com/joelmoss/workroom/internal/workroom"
	"github.com/spf13/cobra"
)

var (
	deleteProjectConfirm string
	deleteProjectWithWR  bool
)

// deleteProjectCmd is an internal, app-only command: it removes a project from the
// config so the macOS app's sidebar can drop it. The human CLI never needs it — a
// project disappears on its own once its last workroom is deleted — so it is hidden
// and available solely in --json mode, which is how the app invokes it.
//
// By default it is strictly config-only: the project entry is deleted and NOTHING on
// disk is touched (worktree directories, branches, and files all stay). With
// --with-workrooms it first tears down every registered workroom (the same per-
// workroom teardown the `delete` command runs: teardown script + VCS worktree/
// workspace removal + dir cleanup, streaming NDJSON logs), then removes the project.
// Branches/bookmarks are never deleted in either mode — the cascade reuses
// Service.Delete, whose VCS removal (`git worktree remove` / `jj workspace forget`)
// leaves refs intact.
var deleteProjectCmd = &cobra.Command{
	Use:    "delete-project [PATH]",
	Short:  "Remove a project (internal; used by the macOS app via --json)",
	Hidden: true,
	Args:   cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		currentCommand = "delete-project"
		svc, err := newService()
		if err != nil {
			return err
		}
		return runDeleteProject(svc, jsonOutput, deleteProjectConfirm, deleteProjectWithWR, args, os.Stdout, os.Stderr)
	},
}

// runDeleteProject holds the command body, decoupled from cobra globals and os
// streams so it is unit-testable with an injected Service (temp config + mock VCS).
// stdout receives the single JSON success envelope; logSink receives NDJSON teardown
// log events during a cascade.
func runDeleteProject(svc *workroom.Service, jsonMode bool, confirm string, withWorkrooms bool, args []string, stdout, logSink io.Writer) error {
	if !jsonMode {
		return fmt.Errorf("delete-project is only available in --json mode")
	}
	if len(args) != 1 {
		return fmt.Errorf("a path argument is required")
	}
	path := args[0]

	// Canonicalize WITHOUT vcs.Detect so a stale or moved project (whose directory
	// no longer exists or is no longer a VCS repo) is still removable from config.
	// CanonicalPath falls back to the absolute path when the dir is absent. The
	// --confirm value must match either form.
	canon, err := config.CanonicalPath(path)
	if err != nil {
		canon = path
	}
	if confirm != canon && confirm != path {
		return fmt.Errorf("%w: --confirm <path> is required and must match the project path", errs.ErrConfirmMismatch)
	}

	if withWorkrooms {
		// Cascade: tear down each workroom in full, streaming teardown output as
		// NDJSON log events on logSink (exactly like `delete`). On the first failure,
		// leave the project in config so the user can retry — workrooms torn down
		// before the failure are gone (same as manual per-workroom deletes), and the
		// error log shows how far it got.
		names, err := svc.Config.WorkroomNames(canon)
		if err != nil {
			return err
		}
		logWriter := newJSONLogWriter(logSink, "teardown")
		svc.ScriptLogWriter = logWriter
		for _, name := range names {
			if err := svc.Delete(canon, name, name); err != nil {
				logWriter.Flush()
				return err
			}
		}
		logWriter.Flush()
	}

	if err := svc.Config.RemoveProject(canon); err != nil {
		return err
	}

	return writeJSONSuccess(stdout, "delete-project", map[string]any{
		"path": canon, "with_workrooms": withWorkrooms,
	})
}

func init() {
	deleteProjectCmd.Flags().StringVar(&deleteProjectConfirm, "confirm", "", "Required in --json mode; must match the project path")
	deleteProjectCmd.Flags().BoolVar(&deleteProjectWithWR, "with-workrooms", false, "Also tear down every workroom (worktree dirs + files; branches kept)")
	rootCmd.AddCommand(deleteProjectCmd)
}

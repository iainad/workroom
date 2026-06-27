package errs

import "errors"

var (
	ErrInWorkroom          = errors.New("looks like you are already in a workroom. Run this command from the root of your main development directory, not from within an existing workroom")
	ErrUnsupportedVCS      = errors.New("no supported VCS detected in this directory. Workroom requires either Git or Jujutsu to manage workspaces")
	ErrInvalidName         = errors.New("workroom name must be alphanumeric (dashes and underscores allowed), and must not start or end with a dash or underscore")
	ErrDirExists           = errors.New("workroom directory already exists")
	ErrJJWorkspaceExists   = errors.New("JJ workspace already exists")
	ErrGitWorktreeExists   = errors.New("Git worktree already exists")
	ErrJJWorkspaceNotFound = errors.New("JJ workspace does not exist")
	ErrGitWorktreeNotFound = errors.New("Git worktree does not exist")
	ErrSetup               = errors.New("setup script failed")
	ErrTeardown            = errors.New("teardown script failed")
	ErrConfirmMismatch     = errors.New("confirmation value does not match the workroom name")
	ErrUnsafeDeletePath    = errors.New("refusing to delete an unsafe or reserved path")
	ErrCancelled           = errors.New("operation cancelled")
	ErrConfigRead          = errors.New("failed to read config")
	ErrConfigWrite         = errors.New("failed to write config")
	ErrVCSCommand          = errors.New("version control command failed")
)

// Code returns a stable, machine-readable identifier for an error, suitable for
// inclusion in the --json contract. Downstream consumers branch on the code, not
// the human message (which may change). Unrecognised errors map to "InternalError".
func Code(err error) string {
	switch {
	case err == nil:
		return ""
	case errors.Is(err, ErrInWorkroom):
		return "InWorkroom"
	case errors.Is(err, ErrUnsupportedVCS):
		return "UnsupportedVCS"
	case errors.Is(err, ErrInvalidName):
		return "InvalidName"
	case errors.Is(err, ErrDirExists):
		return "DirExists"
	case errors.Is(err, ErrJJWorkspaceExists), errors.Is(err, ErrGitWorktreeExists):
		return "WorkspaceExists"
	case errors.Is(err, ErrJJWorkspaceNotFound), errors.Is(err, ErrGitWorktreeNotFound):
		return "WorkspaceNotFound"
	case errors.Is(err, ErrConfirmMismatch):
		return "ConfirmationMismatch"
	case errors.Is(err, ErrUnsafeDeletePath):
		return "UnsafeDeletePath"
	case errors.Is(err, ErrCancelled):
		return "Cancelled"
	case errors.Is(err, ErrSetup):
		return "SetupScriptFailed"
	case errors.Is(err, ErrTeardown):
		return "TeardownScriptFailed"
	case errors.Is(err, ErrConfigRead):
		return "ConfigReadFailed"
	case errors.Is(err, ErrConfigWrite):
		return "ConfigWriteFailed"
	case errors.Is(err, ErrVCSCommand):
		return "VCSCommandFailed"
	default:
		return "InternalError"
	}
}

// ExitCode maps an error to a stable process exit code so non-interactive callers
// can distinguish failure classes:
//
//	0 success · 2 usage/validation · 3 domain precondition/not-found ·
//	4 cancelled/no-op · 5 setup/teardown · 6 config read/write/parse · 1 internal.
func ExitCode(err error) int {
	switch Code(err) {
	case "":
		return 0
	case "ConfirmationMismatch", "UnsafeDeletePath":
		return 2
	case "UnsupportedVCS", "WorkspaceNotFound", "DirExists", "WorkspaceExists", "InvalidName", "InWorkroom":
		return 3
	case "Cancelled":
		return 4
	case "SetupScriptFailed", "TeardownScriptFailed":
		return 5
	case "ConfigReadFailed", "ConfigWriteFailed":
		return 6
	default:
		return 1
	}
}

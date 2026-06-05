package script

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"

	"github.com/joelmoss/workroom/internal/errs"
)

// Run executes a user script in the given workroom directory with environment variables set.
// Combined stdout+stderr is always captured and returned. When stream is non-nil it also
// receives that output live as the script runs, letting callers render a log panel.
//
// The script (setup or teardown) runs with its working directory set to the workroom, and with
// these environment variables available:
//
//	WORKROOM_NAME        the workroom's name
//	WORKROOM_PATH        absolute path to the workroom directory
//	WORKROOM_ROOT_PATH   absolute path to the root project the workroom belongs to
//	WORKROOM_PARENT_DIR  deprecated alias for WORKROOM_ROOT_PATH (kept for existing scripts)
//
// On failure the returned error embeds the captured output only when stream is nil; when a
// stream was provided the output has already been shown, so the error stays concise to avoid
// printing it twice.
func Run(scriptType, scriptPath, workroomDir, name, rootPath string, stream io.Writer) (string, error) {
	if _, err := os.Stat(scriptPath); os.IsNotExist(err) {
		return "", nil
	}

	cmd := exec.Command(scriptPath)
	cmd.Dir = workroomDir
	cmd.Env = append(os.Environ(),
		"WORKROOM_NAME="+name,
		"WORKROOM_PATH="+workroomDir,
		"WORKROOM_ROOT_PATH="+rootPath,
		// Deprecated: superseded by WORKROOM_ROOT_PATH; kept so existing scripts keep working.
		"WORKROOM_PARENT_DIR="+rootPath,
	)

	var buf bytes.Buffer
	var sink io.Writer = &buf
	if stream != nil {
		sink = io.MultiWriter(&buf, stream)
	}
	cmd.Stdout = sink
	cmd.Stderr = sink

	err := cmd.Run()
	output := buf.String()

	if err != nil {
		sentinel := errs.ErrSetup
		if scriptType != "setup" {
			sentinel = errs.ErrTeardown
		}
		if stream != nil {
			return output, fmt.Errorf("%w: %s returned a non-zero exit code", sentinel, scriptPath)
		}
		return output, fmt.Errorf("%w: %s returned a non-zero exit code.\n%s", sentinel, scriptPath, output)
	}

	return output, nil
}

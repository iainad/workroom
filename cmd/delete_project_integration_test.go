package cmd

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/vcs"
	"github.com/joelmoss/workroom/internal/workroom"
)

// run executes a command in dir and fails the test on error. Setup/assertion helper
// for the safety integration tests; everything happens inside t.TempDir().
func run(t *testing.T, dir, name string, args ...string) string {
	t.Helper()
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("%s %s failed: %v\n%s", name, strings.Join(args, " "), err, out)
	}
	return strings.TrimSpace(string(out))
}

// setupGitProject builds a throwaway git repo with one registered workroom (a real
// worktree on a real branch) and returns the canonical project path + the worktree
// dir. All paths live under t.TempDir(); no real project or config is touched.
func setupGitProject(t *testing.T) (svc *workroom.Service, cfg *config.Config, canon, wrPath string) {
	t.Helper()
	tmp := t.TempDir()
	projDir := filepath.Join(tmp, "proj")
	workroomsDir := filepath.Join(tmp, "workrooms")
	if err := os.MkdirAll(projDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(workroomsDir, 0o755); err != nil {
		t.Fatal(err)
	}

	run(t, projDir, "git", "init", "-q")
	run(t, projDir, "git", "config", "user.email", "test@example.com")
	run(t, projDir, "git", "config", "user.name", "Test")
	run(t, projDir, "git", "commit", "-q", "--allow-empty", "-m", "init")

	var err error
	canon, err = config.CanonicalPath(projDir)
	if err != nil {
		t.Fatal(err)
	}
	wrPath = filepath.Join(workroomsDir, "feat")

	g := &vcs.Git{Executor: &vcs.RealExecutor{}}
	if _, err := g.Create(canon, "workroom/feat", wrPath); err != nil {
		t.Fatalf("git worktree add failed: %v", err)
	}

	cfg, err = config.New(filepath.Join(tmp, "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := cfg.SetWorkroomsDir(workroomsDir); err != nil {
		t.Fatal(err)
	}
	if err := cfg.AddWorkroom(canon, "feat", wrPath, "git"); err != nil {
		t.Fatal(err)
	}

	svc = &workroom.Service{
		Config:           cfg,
		VCS:              g,
		Out:              &bytes.Buffer{},
		KeepEmptyProject: true,
	}
	return svc, cfg, canon, wrPath
}

func branchExists(t *testing.T, dir, branch string) bool {
	t.Helper()
	return run(t, dir, "git", "branch", "--list", branch) != ""
}

// TestDeleteProjectSafetyGit_NoFlagKeepsDiskAndBranch is the load-bearing safety
// guarantee: a config-only project delete must NEVER touch disk. The worktree dir
// and its branch both survive.
func TestDeleteProjectSafetyGit_NoFlagKeepsDiskAndBranch(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not available")
	}
	svc, cfg, canon, wrPath := setupGitProject(t)

	if err := runDeleteProject(svc, true, canon, false, []string{canon}, &bytes.Buffer{}, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}

	data, _ := cfg.Read()
	if _, ok := data[canon]; ok {
		t.Fatal("project entry not removed from config")
	}
	if _, err := os.Stat(wrPath); err != nil {
		t.Fatalf("worktree dir must survive a config-only delete, got %v", err)
	}
	if !branchExists(t, canon, "workroom/feat") {
		t.Fatal("branch must survive a config-only delete")
	}
}

// TestDeleteProjectSafetyGit_WithWorkroomsRemovesDirKeepsBranch proves the cascade
// removes the worktree directory but the branch ALWAYS survives — `git worktree
// remove` never deletes refs.
func TestDeleteProjectSafetyGit_WithWorkroomsRemovesDirKeepsBranch(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not available")
	}
	svc, cfg, canon, wrPath := setupGitProject(t)

	if err := runDeleteProject(svc, true, canon, true, []string{canon}, &bytes.Buffer{}, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}

	data, _ := cfg.Read()
	if _, ok := data[canon]; ok {
		t.Fatal("project entry not removed from config after cascade")
	}
	if _, err := os.Stat(wrPath); !os.IsNotExist(err) {
		t.Fatalf("worktree dir must be removed by the cascade, stat err = %v", err)
	}
	if !branchExists(t, canon, "workroom/feat") {
		t.Fatal("HARD INVARIANT VIOLATED: branch deleted by cascade")
	}
}

// TestDeleteProjectSafetyJJ_WithWorkroomsForgetsWorkspaceKeepsRepo mirrors the git
// cascade for jj: the workspace dir is removed and the workspace is forgotten, but
// the repo (and its commits) survive — `jj workspace forget` never abandons changes.
// Skipped when jj is not installed.
func TestDeleteProjectSafetyJJ_WithWorkroomsForgetsWorkspaceKeepsRepo(t *testing.T) {
	if _, err := exec.LookPath("jj"); err != nil {
		t.Skip("jj not available")
	}
	tmp := t.TempDir()
	projDir := filepath.Join(tmp, "proj")
	workroomsDir := filepath.Join(tmp, "workrooms")
	if err := os.MkdirAll(projDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(workroomsDir, 0o755); err != nil {
		t.Fatal(err)
	}
	run(t, projDir, "jj", "git", "init")

	canon, err := config.CanonicalPath(projDir)
	if err != nil {
		t.Fatal(err)
	}
	wrPath := filepath.Join(workroomsDir, "feat")

	j := &vcs.JJ{Executor: &vcs.RealExecutor{}}
	if _, err := j.Create(canon, "workroom/feat", wrPath); err != nil {
		t.Fatalf("jj workspace add failed: %v", err)
	}

	cfg, err := config.New(filepath.Join(tmp, "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := cfg.SetWorkroomsDir(workroomsDir); err != nil {
		t.Fatal(err)
	}
	if err := cfg.AddWorkroom(canon, "feat", wrPath, "jj"); err != nil {
		t.Fatal(err)
	}

	svc := &workroom.Service{Config: cfg, VCS: j, Out: &bytes.Buffer{}, KeepEmptyProject: true}
	if err := runDeleteProject(svc, true, canon, true, []string{canon}, &bytes.Buffer{}, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}

	data, _ := cfg.Read()
	if _, ok := data[canon]; ok {
		t.Fatal("project entry not removed from config after jj cascade")
	}
	if _, err := os.Stat(wrPath); !os.IsNotExist(err) {
		t.Fatalf("jj workspace dir must be removed by the cascade, stat err = %v", err)
	}
	// Repo survives: the default workspace is still listed and the workspace we tore
	// down is forgotten (not present).
	list := run(t, projDir, "jj", "workspace", "list", "--color", "never")
	if !strings.Contains(list, "default") {
		t.Fatalf("default workspace gone — repo damaged: %q", list)
	}
	if strings.Contains(list, "workroom/feat") {
		t.Fatalf("workspace was not forgotten: %q", list)
	}
}

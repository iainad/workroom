package cmd

import (
	"bytes"
	"encoding/json"
	"errors"
	"path/filepath"
	"testing"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/errs"
	"github.com/joelmoss/workroom/internal/vcs"
	"github.com/joelmoss/workroom/internal/workroom"
)

// fakeVCS is a no-disk VCS double: it records the vcsNames passed to Delete and can
// be told to fail on a specific one, so the cascade loop can be exercised without
// shelling out to real git/jj. Type() is git so deleteByName skips the jj-only
// os.RemoveAll path — nothing on disk is touched.
type fakeVCS struct {
	deleteCalls []string
	failOn      string // vcsName to fail on (e.g. "workroom/bravo"); "" never fails
}

func (f *fakeVCS) Type() vcs.Type                           { return vcs.TypeGit }
func (f *fakeVCS) Label() string                            { return "Git" }
func (f *fakeVCS) WorkroomExists(_, _ string) (bool, error) { return true, nil }
func (f *fakeVCS) Create(_, _, _ string) (string, error)    { return "", nil }
func (f *fakeVCS) ListWorkrooms(_ string) ([]string, error) { return nil, nil }
func (f *fakeVCS) Delete(_, vcsName, _ string) (string, error) {
	f.deleteCalls = append(f.deleteCalls, vcsName)
	if f.failOn != "" && vcsName == f.failOn {
		return "", errors.New("boom")
	}
	return "", nil
}

// newTestSvc builds a Service backed by a throwaway temp config and the given VCS
// double — never the real ~/.config/workroom/config.json. KeepEmptyProject mirrors
// --json mode so the cascade keeps the (now-empty) project until RemoveProject runs.
func newTestSvc(t *testing.T, v vcs.VCS) (*workroom.Service, *config.Config) {
	t.Helper()
	dir := t.TempDir()
	cfg, err := config.New(filepath.Join(dir, "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	return &workroom.Service{
		Config:           cfg,
		VCS:              v,
		Out:              &bytes.Buffer{},
		KeepEmptyProject: true,
	}, cfg
}

func TestDeleteProjectRequiresJSON(t *testing.T) {
	svc, _ := newTestSvc(t, &fakeVCS{})
	err := runDeleteProject(svc, false, "", false, []string{"/p"}, &bytes.Buffer{}, &bytes.Buffer{})
	if err == nil || !bytes.Contains([]byte(err.Error()), []byte("only available in --json mode")) {
		t.Fatalf("expected --json-only error, got %v", err)
	}
}

func TestDeleteProjectRequiresPathArg(t *testing.T) {
	svc, _ := newTestSvc(t, &fakeVCS{})
	err := runDeleteProject(svc, true, "", false, []string{}, &bytes.Buffer{}, &bytes.Buffer{})
	if err == nil {
		t.Fatal("expected error when no path argument is given")
	}
}

func TestDeleteProjectConfirmMismatch(t *testing.T) {
	svc, cfg := newTestSvc(t, &fakeVCS{})
	proj := t.TempDir()
	canon, _ := config.CanonicalPath(proj)
	if err := cfg.AddProject(canon, "git"); err != nil {
		t.Fatal(err)
	}

	err := runDeleteProject(svc, true, "wrong-path", false, []string{proj}, &bytes.Buffer{}, &bytes.Buffer{})
	if !errors.Is(err, errs.ErrConfirmMismatch) {
		t.Fatalf("expected ErrConfirmMismatch, got %v", err)
	}
	// The project must still be registered after a rejected confirm.
	data, _ := cfg.Read()
	if _, ok := data[canon]; !ok {
		t.Fatal("project removed despite confirm mismatch")
	}
}

func TestDeleteProjectConfigOnly(t *testing.T) {
	fake := &fakeVCS{}
	svc, cfg := newTestSvc(t, fake)
	proj := t.TempDir()
	canon, _ := config.CanonicalPath(proj)
	if err := cfg.AddWorkroom(canon, "alpha", "/wr/alpha", "git"); err != nil {
		t.Fatal(err)
	}

	var stdout bytes.Buffer
	// confirm matches the as-given path (gate accepts canon OR path).
	if err := runDeleteProject(svc, true, proj, false, []string{proj}, &stdout, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}

	// No VCS teardown without --with-workrooms.
	if len(fake.deleteCalls) != 0 {
		t.Fatalf("config-only delete touched VCS: %v", fake.deleteCalls)
	}
	// Project entry gone.
	data, _ := cfg.Read()
	if _, ok := data[canon]; ok {
		t.Fatal("project entry not removed")
	}
	// Envelope shape.
	var env map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &env); err != nil {
		t.Fatalf("bad envelope %q: %v", stdout.String(), err)
	}
	if env["ok"] != true || env["command"] != "delete-project" || env["path"] != canon || env["with_workrooms"] != false {
		t.Fatalf("unexpected envelope: %v", env)
	}
}

func TestDeleteProjectCascade(t *testing.T) {
	fake := &fakeVCS{}
	svc, cfg := newTestSvc(t, fake)
	proj := t.TempDir()
	canon, _ := config.CanonicalPath(proj)
	for _, n := range []string{"bravo", "alpha"} { // insertion order; cascade should sort
		if err := cfg.AddWorkroom(canon, n, "/wr/"+n, "git"); err != nil {
			t.Fatal(err)
		}
	}

	var stdout, logs bytes.Buffer
	if err := runDeleteProject(svc, true, canon, true, []string{proj}, &stdout, &logs); err != nil {
		t.Fatal(err)
	}

	// Both workrooms torn down, in sorted order, via "workroom/<name>".
	if len(fake.deleteCalls) != 2 || fake.deleteCalls[0] != "workroom/alpha" || fake.deleteCalls[1] != "workroom/bravo" {
		t.Fatalf("expected [workroom/alpha workroom/bravo], got %v", fake.deleteCalls)
	}
	// Project removed.
	data, _ := cfg.Read()
	if _, ok := data[canon]; ok {
		t.Fatal("project entry not removed after cascade")
	}
	var env map[string]any
	_ = json.Unmarshal(stdout.Bytes(), &env)
	if env["with_workrooms"] != true {
		t.Fatalf("expected with_workrooms:true, got %v", env)
	}
}

func TestDeleteProjectCascadePartialFailureKeepsProject(t *testing.T) {
	fake := &fakeVCS{failOn: "workroom/bravo"}
	svc, cfg := newTestSvc(t, fake)
	proj := t.TempDir()
	canon, _ := config.CanonicalPath(proj)
	for _, n := range []string{"alpha", "bravo"} {
		if err := cfg.AddWorkroom(canon, n, "/wr/"+n, "git"); err != nil {
			t.Fatal(err)
		}
	}

	err := runDeleteProject(svc, true, canon, true, []string{proj}, &bytes.Buffer{}, &bytes.Buffer{})
	if err == nil {
		t.Fatal("expected cascade to surface the teardown failure")
	}
	// alpha was torn down before bravo failed; the loop stops at bravo.
	if len(fake.deleteCalls) != 2 {
		t.Fatalf("expected 2 delete attempts (alpha ok, bravo fail), got %v", fake.deleteCalls)
	}
	// Project must remain in config so the user can retry.
	data, _ := cfg.Read()
	if _, ok := data[canon]; !ok {
		t.Fatal("project removed despite a cascade failure (should be retryable)")
	}
}

package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestCanonicalPathTildeExpansion covers the new behaviour (issue #103, 2A):
// a leading ~ / ~/ expands to the user's home directory. Because CanonicalPath
// is shared by every command, the same test also pins the UNCHANGED behaviour
// for absolute, relative, missing, and ~user paths so the expansion can't regress
// the existing callers.
func TestCanonicalPathTildeExpansion(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("no home dir")
	}

	t.Run("bare tilde expands to home", func(t *testing.T) {
		got, err := CanonicalPath("~")
		if err != nil {
			t.Fatal(err)
		}
		// home itself exists, so it resolves through EvalSymlinks; compare resolved.
		want, _ := filepath.EvalSymlinks(home)
		if got != want {
			t.Fatalf("CanonicalPath(\"~\") = %q, want %q", got, want)
		}
	})

	t.Run("tilde slash expands under home", func(t *testing.T) {
		got, err := CanonicalPath("~/some/missing/child")
		if err != nil {
			t.Fatal(err)
		}
		// The child does not exist, so it stays absolute (no symlink eval), but it
		// must be rooted at home, not at the cwd.
		want := filepath.Join(home, "some", "missing", "child")
		if got != want {
			t.Fatalf("CanonicalPath(\"~/some/missing/child\") = %q, want %q", got, want)
		}
	})

	t.Run("tilde-user is NOT expanded", func(t *testing.T) {
		got, err := CanonicalPath("~someuser/x")
		if err != nil {
			t.Fatal(err)
		}
		// Only ~ and ~/ are handled; ~user stays literal (resolved against cwd).
		if !strings.Contains(got, "~someuser") {
			t.Fatalf("~someuser should not be home-expanded, got %q", got)
		}
	})

	t.Run("absolute path unchanged", func(t *testing.T) {
		dir := t.TempDir()
		got, err := CanonicalPath(dir)
		if err != nil {
			t.Fatal(err)
		}
		want, _ := filepath.EvalSymlinks(dir)
		if got != want {
			t.Fatalf("absolute path = %q, want %q", got, want)
		}
	})

	t.Run("missing absolute path returns abs, no error", func(t *testing.T) {
		p := filepath.Join(t.TempDir(), "does", "not", "exist")
		got, err := CanonicalPath(p)
		if err != nil {
			t.Fatalf("missing path should not error, got %v", err)
		}
		if got != p {
			t.Fatalf("missing path = %q, want %q", got, p)
		}
	})

	t.Run("symlinked dir resolves to target", func(t *testing.T) {
		real := t.TempDir()
		link := filepath.Join(t.TempDir(), "link")
		if err := os.Symlink(real, link); err != nil {
			t.Skipf("symlink unsupported: %v", err)
		}
		got, err := CanonicalPath(link)
		if err != nil {
			t.Fatal(err)
		}
		want, _ := filepath.EvalSymlinks(real)
		if got != want {
			t.Fatalf("symlink resolved to %q, want %q", got, want)
		}
	})
}

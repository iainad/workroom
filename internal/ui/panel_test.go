package ui

import (
	"bytes"
	"strings"
	"testing"

	"github.com/fatih/color"
)

func TestLogPanelStreamsLinesWithGutter(t *testing.T) {
	color.NoColor = true
	var buf bytes.Buffer
	p := NewLogPanel(&buf, "Setup")
	if p.Shown() {
		t.Fatal("panel should not report Shown before any write")
	}

	p.Write([]byte("line one\nline two\n"))
	p.Close(true)

	out := buf.String()
	if !p.Shown() {
		t.Fatal("panel should report Shown after writing")
	}
	if !strings.Contains(out, "╭─ Setup ") {
		t.Fatalf("expected titled header, got:\n%s", out)
	}
	if !strings.Contains(out, "│ line one") || !strings.Contains(out, "│ line two") {
		t.Fatalf("expected gutter-prefixed lines, got:\n%s", out)
	}
	if !strings.Contains(out, "╰") {
		t.Fatalf("expected footer rule, got:\n%s", out)
	}
}

func TestLogPanelHandlesChunkedWritesAndTrailingPartial(t *testing.T) {
	color.NoColor = true
	var buf bytes.Buffer
	p := NewLogPanel(&buf, "Setup")

	// A single line split across writes, plus a trailing partial with no newline.
	p.Write([]byte("hel"))
	p.Write([]byte("lo\r\nworld"))
	p.Close(true)

	out := buf.String()
	if !strings.Contains(out, "│ hello") {
		t.Fatalf("expected reassembled 'hello' line (CR trimmed), got:\n%s", out)
	}
	if !strings.Contains(out, "│ world") {
		t.Fatalf("expected trailing partial 'world' flushed on close, got:\n%s", out)
	}
}

func TestLogPanelNoOutputDrawsNothing(t *testing.T) {
	color.NoColor = true
	var buf bytes.Buffer
	p := NewLogPanel(&buf, "Setup")
	p.Close(true) // never written to

	if buf.Len() != 0 {
		t.Fatalf("expected no output for an unused panel, got:\n%s", buf.String())
	}
	if p.Shown() {
		t.Fatal("unused panel should not report Shown")
	}
}

func TestLogPanelFailureFooter(t *testing.T) {
	color.NoColor = true
	var buf bytes.Buffer
	p := NewLogPanel(&buf, "Setup")
	p.Write([]byte("boom\n"))
	p.Close(false)

	if !strings.Contains(buf.String(), "Setup failed") {
		t.Fatalf("expected failure footer, got:\n%s", buf.String())
	}
}

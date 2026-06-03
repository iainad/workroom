package ui

import (
	"bytes"
	"fmt"
	"io"
	"strings"
	"unicode/utf8"
)

// panelWidth is the target column width for a panel's top and bottom rules. Content
// lines are not truncated or padded to it — the rules are purely decorative.
const panelWidth = 60

// LogPanel renders streamed command output inside a titled, bordered panel. It
// implements io.Writer, so it can be handed straight to a running command as its
// stdout/stderr sink: each complete line is rendered with a gutter border as it
// arrives. The header is drawn lazily on the first byte, so a command that produces
// no output draws no panel at all. Call Close when the command finishes.
//
// A LogPanel is not safe for concurrent use.
type LogPanel struct {
	w       io.Writer
	title   string
	started bool
	partial []byte // bytes received since the last newline, not yet rendered
}

// NewLogPanel returns a panel that renders to w with the given title.
func NewLogPanel(w io.Writer, title string) *LogPanel {
	return &LogPanel{w: w, title: title}
}

// Shown reports whether the panel has rendered anything yet (i.e. the command
// produced output). Callers use this to decide on surrounding whitespace.
func (p *LogPanel) Shown() bool {
	return p.started
}

func (p *LogPanel) start() {
	if p.started {
		return
	}
	p.started = true
	title := " " + p.title + " "
	n := max(0, panelWidth-2-utf8.RuneCountInString(title))
	fmt.Fprintln(p.w, Dim("╭─")+Bold(Blue(title))+Dim(strings.Repeat("─", n)))
}

// Write implements io.Writer. It is safe to call with arbitrary chunk boundaries:
// bytes are buffered until a newline, then rendered as a gutter-prefixed line.
func (p *LogPanel) Write(b []byte) (int, error) {
	p.start()
	p.partial = append(p.partial, b...)
	for {
		i := bytes.IndexByte(p.partial, '\n')
		if i < 0 {
			break
		}
		p.writeLine(string(p.partial[:i]))
		p.partial = p.partial[i+1:]
	}
	return len(b), nil
}

func (p *LogPanel) writeLine(line string) {
	fmt.Fprintf(p.w, "%s %s\n", Dim("│"), strings.TrimSuffix(line, "\r"))
}

// Close flushes any trailing partial line and renders the footer. ok controls
// whether the footer reads as success or failure. If nothing was ever written the
// panel was never started, and Close renders nothing.
func (p *LogPanel) Close(ok bool) {
	if !p.started {
		return
	}
	if len(p.partial) > 0 {
		p.writeLine(string(p.partial))
		p.partial = nil
	}
	if ok {
		fmt.Fprintln(p.w, Dim("╰"+strings.Repeat("─", panelWidth-1)))
		return
	}
	label := " " + p.title + " failed "
	n := max(0, panelWidth-2-utf8.RuneCountInString(label))
	fmt.Fprintln(p.w, Dim("╰─")+Red(label)+Dim(strings.Repeat("─", n)))
}

# Workroom

### Mission control for every branch you're running at once.

Spin up a workroom, get a terminal, get notified.

**Workroom is a native [macOS app](#the-macos-app) for running many copies of a project at once.**
Every project gets a sidebar; every workroom inside it gets its own persistent terminal. Spin a new
workroom up in one click, jump between their terminals freely without losing a running build or dev
server, and get notified the moment one finishes or needs your input — instead of hunting through a
wall of terminal tabs to find out.

Under the hood, a workroom is a full, isolated copy of your project — its own
[Git](https://git-scm.com/) worktree or [Jujutsu](https://martinvonz.github.io/jj/) workspace, so
you can work on several branches or features at the same time without stashing, switching, or
tripping over uncommitted changes. Workroom does all that bookkeeping for you (auto-detecting Git
vs JJ) and keeps your workrooms under a central directory (`~/workrooms` by default, configurable
via `workrooms_dir` in `~/.config/workroom/config.json`).

The app bundles and drives the same `workroom` engine that also ships as a
[standalone CLI](#the-cli-standalone) — handy for terminal-first workflows, and the only option on
Linux/Windows.

## The macOS app

> **🚧 Beta.** The macOS app is young and under active development — expect rough edges, and some
> flows still want polish. [Bug reports and feedback](https://github.com/joelmoss/workroom/issues)
> are very welcome.

The native app (macOS 14 Sonoma or later, Apple Silicon) is a home for every project you work on
and every workroom inside it. Pick a workroom in the sidebar, get a real terminal already `cd`'d
into it, and run whatever you like — Workroom keeps each one alive and out of the others' way.

### Install

Download the latest `workroom-macos-app_<version>.dmg` from the
[Releases page](https://github.com/joelmoss/workroom/releases/latest), open it, and drag
**Workroom** into Applications. The app is Developer ID-signed and notarized, so it launches with
no Gatekeeper warning — and it **updates itself** in the background (or on demand via
*Workroom ▸ Check for Updates…*).

That's the whole install. The `workroom` CLI is bundled inside the app and driven for you, so
there's nothing else to download. Want the command in your own shell too? *Workroom ▸ Install
‘workroom’ Command in PATH…* symlinks it into your `PATH` (prompting for admin once if needed).

Building from source instead? See [`macapp/README.md`](macapp/README.md) (`make app-run`).

### What you get

**A sidebar of everything you're working on.** Each project expands into its workrooms as a tree,
and every row shows its current Git branch or JJ bookmark inline — with an "ahead of upstream"
marker and a warning when a folder has gone missing. Add a project, expand/collapse it, and pick a
target; your layout, selection, and expansion state are remembered across launches.

**A live terminal in every workroom.** Selecting a workroom gives you an embedded terminal (powered
by [libghostty](https://ghostty.org)) already in the right directory. Each workroom keeps **its own
terminal alive for the session** — switch away to another workroom and your dev server, build, or
REPL keeps running, ready exactly as you left it when you come back. Open as many terminals per
target as you want in a draggable tab strip; tabs label themselves with the running command or
working directory.

**See work happening at a glance.** While a command runs, the tab and its sidebar row animate so
you can tell what's busy without switching to it. When a backgrounded terminal posts a notification,
its tab and project light up, and — if Workroom isn't the frontmost app — you get a desktop banner.
A notifications inspector keeps the history; click any entry (or the banner) to jump straight to the
terminal that raised it.

**Create and delete without touching the command line.** Hit the **+** on a project to spin up a
new workroom. Your `scripts/workroom_setup` runs behind a live progress overlay so you watch
dependencies install and config copy in real time, and the terminal opens only once setup is done.
Deleting is a hover-to-trash with a confirmation; teardown runs in the background and the row clears
immediately. (See [Setup and teardown scripts](#setup-and-teardown-scripts).)

**Jump in with the keyboard.** `⌘1`–`⌘9` focus terminals left-to-right, `⌘T` opens a new one, `⌘W`
closes the active one (with an optional confirm), and `⌘O` adds a project. A global `⌘§` hotkey
shows or hides Workroom from anywhere.

**Stay in your editor.** `⌘`-click a file path in any terminal to open it in your editor — VS Code,
Zed, or Xcode — at the right working directory. The detail toolbar also has *Open in…*, *Reveal in
Finder*, and *Copy Path* for the selected workroom.

**Make it yours.** System / Light / Dark theming (terminals re-theme live), copy-on-select,
confirm-before-quit and confirm-before-close toggles, and an editor preference all live in
Preferences (`⌘,`).

## The CLI (standalone)

Prefer the terminal, or running on Linux/Windows? The `workroom` CLI does everything on its own.
(Skip this entirely if you use the macOS app — it already bundles the CLI and drives it for you.)

### Installation

**macOS / Linux:**

```bash
curl -fsSL https://raw.githubusercontent.com/joelmoss/workroom/master/install.sh | sh
```

**Windows (PowerShell):**

```powershell
iwr https://raw.githubusercontent.com/joelmoss/workroom/master/install.ps1 -useb | iex
```

**Install a specific version:**

```bash
VERSION=v1.2.0 curl -fsSL https://raw.githubusercontent.com/joelmoss/workroom/master/install.sh | sh
```

**Override install location (macOS / Linux):**

By default, the binary is installed to `~/.local/bin`. Set `WORKROOM_INSTALL_PATH` to change this:

```bash
WORKROOM_INSTALL_PATH=/usr/local/bin curl -fsSL https://raw.githubusercontent.com/joelmoss/workroom/master/install.sh | sh
```

#### Alternative methods

**Via Go:**

```bash
go install github.com/joelmoss/workroom@latest
```

**Build from source:**

```bash
git clone https://github.com/joelmoss/workroom.git
cd workroom
make cli-build
```

### Requirements

- [JJ (Jujutsu)](https://martinvonz.github.io/jj/) or [Git](https://git-scm.com/)

### CLI Usage

#### Create a workroom

```bash
workroom create
```

A random friendly name (e.g. `swift-meadow`) is auto-generated. Workroom automatically detects whether you're using JJ or Git and uses the appropriate mechanism (JJ workspace or git worktree).

Alias: `workroom c`

#### List workrooms

```bash
workroom list
```

Lists all workrooms for the current project. When run from outside a known project, lists all workrooms grouped by parent project. When run from inside a workroom, shows the parent project path.

Aliases: `workroom ls`, `workroom l`

#### Delete a workroom

```bash
workroom delete my-feature
```

Removes the workspace/worktree and cleans up the directory. You'll be prompted for confirmation before deletion.

When run without a name, an interactive multi-select menu is shown, allowing you to pick one or more workrooms to delete:

```bash
workroom delete
```

To skip the confirmation prompt (useful for scripting), pass `--confirm` with the workroom name:

```bash
workroom delete my-feature --confirm my-feature
```

Alias: `workroom d`

#### Options

- `-v`, `--verbose` - Print detailed output
- `-p`, `--pretend` - Run through the command without making changes (dry run)
- `--confirm NAME` - Skip delete confirmation when NAME matches the workroom being deleted

## Setup and teardown scripts

Both the macOS app **and** the CLI automatically run user-defined scripts during create and delete
operations — the app drives the same engine, so the same hooks work no matter how you use Workroom.

### Setup script

Place an executable script at `scripts/workroom_setup` in your project (remember `chmod +x`). It
runs **inside the new workroom** right after creation — a good place to install dependencies and
pull in gitignored local config that the worktree/workspace doesn't carry over. (In the macOS app,
its output streams into the setup overlay as it runs.)

```bash
#!/usr/bin/env bash
set -euo pipefail

# A fresh workroom is a clean checkout, so copy gitignored local config (e.g. .env)
# from the root project this workroom belongs to.
cp "$WORKROOM_ROOT_PATH/.env" .env 2>/dev/null || true

# Install dependencies for this isolated copy.
npm install

# Give the workroom its own database, named after it, so it can't clobber others.
createdb "myapp_${WORKROOM_NAME}"
```

### Teardown script

Place an executable script at `scripts/workroom_teardown` in your project (`chmod +x`). It runs
**inside the workroom** just before it's deleted — undo anything setup created that lives outside
the workroom (the directory itself is removed for you):

```bash
#!/usr/bin/env bash
set -euo pipefail

# Drop the per-workroom database that setup created.
dropdb "myapp_${WORKROOM_NAME}" 2>/dev/null || true
```

### Environment variables

The same environment variables are available to **both** the setup and teardown scripts:

- `WORKROOM_NAME` — The name of the workroom being created or deleted.
- `WORKROOM_PATH` — The absolute path to the workroom directory (also the script's working directory).
- `WORKROOM_ROOT_PATH` — The absolute path to the root project the workroom belongs to. Since scripts run inside the workroom directory, this lets you reference files back in the original project.
- `WORKROOM_PARENT_DIR` — _Deprecated_ alias for `WORKROOM_ROOT_PATH`, still set for existing scripts. Prefer `WORKROOM_ROOT_PATH`.

## Releasing

Pushing a version tag triggers GitHub Actions to publish a release with **both** components:

- the CLI binaries for every platform — `workroom-cli_<version>_<os>_<arch>.{tar.gz,zip}`
- the signed, notarized macOS app installer — `workroom-macos-app_<version>.dmg` — plus an updated
  Sparkle appcast so existing app installs can auto-update

```bash
git tag v1.4.0
git push origin v1.4.0
```

You can test the CLI build locally with [GoReleaser](https://goreleaser.com/) before tagging
(produces binaries in `dist/` without publishing):

```bash
goreleaser build --snapshot --clean
```

The macOS app release flow (sign → notarize → staple → DMG → appcast) is documented in
[`macapp/README.md`](macapp/README.md).

## License

[MIT](MIT-LICENSE)

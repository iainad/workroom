# Workroom

Work on several branches or features of a project at once — each in its own isolated copy —
without stashing, switching, or tripping over uncommitted changes. Workroom manages those copies
("workrooms") for you using [Git](https://git-scm.com/) worktrees or
[Jujutsu](https://martinvonz.github.io/jj/) workspaces, auto-detecting which your project uses.

A workroom is a full, isolated copy of your project. Spin one up per feature or bugfix, jump
between them freely, and keep using whatever editor or IDE you like — Workroom handles the
worktree/workspace bookkeeping. Workrooms live under a central directory (`~/workrooms` by
default, configurable via `workrooms_dir` in `~/.config/workroom/config.json`).

Workroom comes in two forms that share the same engine:

- **The Workroom macOS app** — a native app with a sidebar of your projects and their workrooms,
  embedded terminals, and one-click create/delete. **This is the recommended way to use Workroom.**
- **The `workroom` CLI** — a single binary that does everything from the terminal. Use it
  standalone if you prefer the command line or are on Linux/Windows. **You don't need it if you
  use the macOS app — the app bundles the CLI and drives it for you.**

## The macOS app

The native app (macOS 14 Sonoma or later, Apple Silicon) gives you a sidebar of projects and
their workrooms, an embedded terminal per workroom, theming, desktop notifications, and ⌘-click to
open file paths in your editor.

**Install:** download the latest `workroom-macos-app_<version>.dmg` from the
[Releases page](https://github.com/joelmoss/workroom/releases/latest), open it, and drag
**Workroom** into Applications. The app is Developer ID-signed and notarized, so it launches with
no Gatekeeper warning — and it **updates itself** in the background (or on demand via
*Workroom ▸ Check for Updates…*).

Want the `workroom` command available in your terminal too? The app installs it on request:
*Workroom ▸ Install ‘workroom’ Command in PATH…* (no separate download needed).

Build and run it from source with `make app-run` (see [`macapp/README.md`](macapp/README.md)).

## The CLI (standalone)

Prefer the terminal, or running on Linux/Windows? The `workroom` CLI does everything on its own.
(Skip this entirely if you use the macOS app — it already includes the CLI.)

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

### Usage

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

Both the CLI **and** the macOS app automatically run user-defined scripts during create and
delete operations — the app drives the same engine, so the same hooks work no matter how you use
Workroom.

### Setup script

Place an executable script at `scripts/workroom_setup` in your project (remember `chmod +x`). It
runs **inside the new workroom** right after creation — a good place to install dependencies and
pull in gitignored local config that the worktree/workspace doesn't carry over:

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

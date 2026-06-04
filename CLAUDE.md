# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Workroom is a standalone CLI tool (Go binary) for creating and managing development workrooms using Git worktrees or JJ (Jujutsu) workspaces. It auto-detects VCS type, generates friendly workroom names, and manages configuration at `~/.config/workroom/config.json`.

This repo has two components: the **Go CLI** (root, documented below) and a **macOS app** (`macapp/` — see `macapp/CLAUDE.md`) that bundles the CLI and drives it over the machine-readable `--json` API (`list`/`create`/`delete`/`add-project --json`).

## Build & Test

```bash
go build -o workroom .              # build binary
go test ./...                       # run all tests
go test ./internal/workroom/ -v     # run workroom tests verbose
```

Dev tasks run through the repo-root `Makefile`, namespaced `cli-*` (Go CLI) and `app-*` (macOS
app under `macapp/`). `make` with no target lists them. The Go CLI:

```bash
make cli-build                      # build with version injection
make cli-test                       # run tests
make cli-lint                       # golangci-lint (config: .golangci.yml)
make cli-install                    # install to $GOBIN
```

`cli-lint` requires `golangci-lint` (v1.x): `go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest`.
The macOS app targets (`app-build`, `app-run`, `app-test`, `app-format`, `app-lint`, …) are
documented in `macapp/CLAUDE.md`.

## Architecture

Go project using Cobra for CLI, with clean internal package separation:

- `main.go` — Entry point, sets version via ldflags
- `cmd/` — Cobra command definitions (root, create, list, delete, version)
- `internal/config/` — JSON config CRUD at `~/.config/workroom/config.json`
- `internal/namegen/` — Adjective-noun name generation (120 adjectives, 210 nouns)
- `internal/vcs/` — VCS interface + JJ/Git implementations with `CommandExecutor` for testability
- `internal/workroom/` — Core orchestration: create/delete/list flows
- `internal/script/` — Setup/teardown script runner with env vars
- `internal/ui/` — Colored output, table printing, interactive prompts (huh library)
- `internal/errs/` — Shared error sentinels

### Subcommands

- `workroom create` (alias: `c`) — Auto-generate name, create VCS workspace, update config, run setup script
- `workroom list` (aliases: `ls`, `l`) — List workrooms for current project or all projects
- `workroom delete [NAME]` (alias: `d`) — Delete by name with `--confirm`, or interactive multi-select
- `workroom version` — Print version

### Flags

- `-v`/`--verbose` — Detailed output
- `-p`/`--pretend` — Dry run
- `--confirm NAME` — Skip delete confirmation (delete subcommand only)

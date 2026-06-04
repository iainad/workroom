# Repo-wide dev tasks, namespaced: `cli-*` = the Go CLI (the primary product), `app-*` = the
# macOS app under macapp/ (Xcode-based). Run `make` with no target to list them.
#
# App recipes run inside macapp/ and need its toolchain on PATH (xcodegen via Homebrew). The
# Xcode build also runs project.yml phases — a non-fatal swift-format lint and embedding the Go
# helper (macapp/Scripts/build-helper.sh). `cli-lint` needs golangci-lint installed (see CLAUDE.md).
export PATH := /opt/homebrew/bin:/usr/local/bin:$(PATH)
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)

.DEFAULT_GOAL := help
.PHONY: help \
        cli-build cli-test cli-install cli-lint cli-clean \
        app-run app-build app-test app-generate app-format app-lint app-release app-icon app-clean

help: ## List available targets
	@grep -hE '^[a-z][a-zA-Z0-9_-]*:.*## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*## "}{printf "  \033[36m%-13s\033[0m %s\n", $$1, $$2}'

# --- Go CLI (repo root) ---

cli-build: ## Build the workroom binary (version injected)
	go build -ldflags "-X main.version=$(VERSION)" -o workroom .

cli-test: ## Run the Go tests
	go test ./...

cli-install: ## Install the binary to $GOBIN
	go install -ldflags "-X main.version=$(VERSION)" .

cli-lint: ## Lint Go with golangci-lint
	golangci-lint run

cli-clean: ## Remove the built binary
	rm -f workroom

# --- macOS app (macapp/) ---

APP_PROJECT := WorkroomApp.xcodeproj
APP_BUNDLE  := DerivedData/Build/Products/Debug/Workroom.app
APP_XCODEBUILD := xcodebuild -project $(APP_PROJECT) -scheme WorkroomApp -configuration Debug \
  -derivedDataPath DerivedData -clonedSourcePackagesDirPath DerivedData/SourcePackages

app-run: app-build ## Build (Debug) and launch the app, replacing any running instance
	cd macapp || exit 1; \
	pkill -x Workroom 2>/dev/null || true; \
	for _ in 1 2 3 4 5 6 7 8 9 10; do \
	  pgrep -x Workroom >/dev/null 2>&1 || break; \
	  sleep 0.2; \
	done; \
	echo "Launching $(APP_BUNDLE)"; \
	open "$(APP_BUNDLE)"

app-build: ## Build the app (Debug)
	cd macapp && { [ -d $(APP_PROJECT) ] || xcodegen generate; } && $(APP_XCODEBUILD) build

app-test: ## Run the app's unit tests
	cd macapp && { [ -d $(APP_PROJECT) ] || xcodegen generate; } && $(APP_XCODEBUILD) -destination 'platform=macOS' test

app-generate: ## Force-regenerate the (gitignored) .xcodeproj from project.yml
	cd macapp && xcodegen generate

app-format: ## Format Swift sources in place (swift-format)
	cd macapp && xcrun swift-format format --in-place --parallel --recursive WorkroomApp WorkroomAppTests

app-lint: ## Lint Swift with swift-format (--strict)
	cd macapp && xcrun swift-format lint --strict --parallel --recursive WorkroomApp WorkroomAppTests

app-release: ## Build, notarize and staple a Release app (macapp/Scripts/release.sh)
	cd macapp && Scripts/release.sh

app-icon: ## Regenerate the AppIcon PNGs (macapp/Scripts/make-icon.swift)
	cd macapp && swift Scripts/make-icon.swift

app-clean: ## Remove the app's DerivedData + .xcodeproj
	cd macapp && rm -rf DerivedData $(APP_PROJECT)

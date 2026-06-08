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

# Extra xcodebuild build-setting overrides, appended to app-build/app-test. Empty locally so
# ⌘R-style automatic signing is used; CI sets this to ad-hoc / no-team signing because hosted
# runners have no signing cert or DEVELOPMENT_TEAM (e.g.
# `make app-test APP_SIGN_FLAGS="CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM="`).
APP_SIGN_FLAGS ?=

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
	cd macapp && xcodegen generate && $(APP_XCODEBUILD) build $(APP_SIGN_FLAGS)

app-test: ## Run the app's unit tests
	cd macapp && xcodegen generate && $(APP_XCODEBUILD) -destination 'platform=macOS' test $(APP_SIGN_FLAGS)

app-uitest: ## Run the app's UI tests (XCUITest — needs a real GUI login session, not headless)
	cd macapp && xcodegen generate && xcodebuild -project $(APP_PROJECT) -scheme WorkroomAppUITests -configuration Debug -derivedDataPath DerivedData -clonedSourcePackagesDirPath DerivedData/SourcePackages -destination 'platform=macOS' test $(APP_SIGN_FLAGS)

app-generate: ## Force-regenerate the (gitignored) .xcodeproj from project.yml
	cd macapp && xcodegen generate

app-format: ## Format Swift sources in place (swift-format)
	cd macapp && xcrun swift-format format --in-place --parallel --recursive WorkroomApp WorkroomAppTests WorkroomAppUITests

app-lint: ## Lint Swift with swift-format (--strict)
	cd macapp && xcrun swift-format lint --strict --parallel --recursive WorkroomApp WorkroomAppTests WorkroomAppUITests

app-release: ## Build, notarize, staple + package a DMG installer (macapp/Scripts/release.sh)
	cd macapp && Scripts/release.sh

app-icon: ## Regenerate the AppIcon PNGs (macapp/Scripts/make-icon.swift)
	cd macapp && swift Scripts/make-icon.swift

app-clean: ## Remove the app's DerivedData + .xcodeproj
	cd macapp && rm -rf DerivedData $(APP_PROJECT)

import Carbon.HIToolbox
import XCTest

@testable import Workroom

/// The quick-terminal lifecycle (issue #39): ABSENT → summon a fresh ~/ window, hide keeps the
/// surface alive across a re-summon, and a close fully tears it down so the next summon is fresh.
/// Surfaces are injected non-spawning (`spawnsSurface: false`) so no real PTY / Metal renderer is
/// created — mounting and tearing one down is unsafe in the headless test host.
@MainActor
final class QuickTerminalControllerTests: XCTestCase {
  private func makeController() -> QuickTerminalController {
    let controller = QuickTerminalController()
    controller.makeSurface = {
      GhosttySurfaceView(workingDirectory: "/tmp", command: nil, spawnsSurface: false)
    }
    return controller
  }

  func testDefaultSurfaceOpensAtHome() {
    // The default factory (the real app path) spawns the shell at ~/. Inspect it without mounting,
    // so no surface is actually created.
    let surface = QuickTerminalController().makeSurface()
    XCTAssertEqual(surface.workingDirectory, NSHomeDirectory())
  }

  func testToggleFromAbsentCreatesVisibleWindow() {
    let controller = makeController()
    defer { controller.close() }

    XCTAssertFalse(controller.hasWindow)
    controller.toggle()

    XCTAssertTrue(controller.hasWindow)
    XCTAssertTrue(controller.isVisible)
    XCTAssertNotNil(controller.currentSurface)
  }

  func testToggleWhenVisibleHidesButKeepsSurface() {
    let controller = makeController()
    defer { controller.close() }

    controller.toggle()  // → VISIBLE
    let surface = controller.currentSurface
    controller.toggle()  // → HIDDEN

    XCTAssertFalse(controller.isVisible)
    XCTAssertTrue(controller.hasWindow, "hidden, not destroyed")
    XCTAssertTrue(controller.currentSurface === surface, "same surface persists across hide")
  }

  func testToggleWhenHiddenShowsSameSurface() {
    let controller = makeController()
    defer { controller.close() }

    controller.toggle()  // VISIBLE
    let surface = controller.currentSurface
    controller.toggle()  // HIDDEN
    controller.toggle()  // VISIBLE again

    XCTAssertTrue(controller.isVisible)
    XCTAssertTrue(controller.currentSurface === surface, "re-summon restores the same session")
  }

  func testCloseTearsDownAndNextSummonIsFresh() {
    let controller = makeController()
    controller.toggle()
    let first = controller.currentSurface

    controller.close()
    XCTAssertFalse(controller.hasWindow)
    XCTAssertNil(controller.currentSurface)

    controller.toggle()  // a brand-new terminal — no session resurrection
    defer { controller.close() }
    XCTAssertNotNil(controller.currentSurface)
    XCTAssertFalse(controller.currentSurface === first, "reopen creates a different surface")
  }

  func testWindowIsChromeLessButClosable() throws {
    let controller = makeController()
    defer { controller.close() }
    controller.toggle()

    let window = try XCTUnwrap(controller.currentWindow)
    XCTAssertTrue(window is QuickTerminalWindow, "tag type the ⌘W key monitor matches on")
    XCTAssertEqual(window.titleVisibility, .hidden)
    XCTAssertTrue(window.titlebarAppearsTransparent)
    XCTAssertNil(window.toolbar, "no toolbar — chrome-less")
    XCTAssertNotNil(
      window.standardWindowButton(.closeButton), "traffic lights kept so it's closable + movable")
  }
}

/// The hotkey-dispatch fix (issue #39): with two global hotkeys live, each installed Carbon handler
/// sees every press, so it must act only on its own id — otherwise the first-installed handler
/// swallows every press and fires the wrong action. `GlobalHotkey.matches` is that filter.
final class GlobalHotkeyDispatchTests: XCTestCase {
  func testMatchesOnlyOwnSignatureAndID() {
    let ours = EventHotKeyID(signature: GlobalHotkey.signature, id: 2)
    XCTAssertTrue(GlobalHotkey.matches(ours, id: 2), "our id-2 hotkey handles its own press")
    XCTAssertFalse(GlobalHotkey.matches(ours, id: 1), "id-1 instance must ignore the id-2 press")
  }

  func testIgnoresForeignSignature() {
    let foreign = EventHotKeyID(signature: OSType(0x1234_5678), id: 1)
    XCTAssertFalse(
      GlobalHotkey.matches(foreign, id: 1), "another app's hotkey id must never be handled")
  }
}

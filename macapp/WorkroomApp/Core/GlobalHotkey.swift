import AppKit
import Carbon.HIToolbox

/// A single system-wide hotkey registered through Carbon's `RegisterEventHotKey`. Unlike an
/// `NSEvent` global monitor it fires regardless of which app is frontmost, consumes the key, and
/// needs no Accessibility permission — the standard backing for a show/hide-the-app shortcut
/// (issue #13). Hold the instance for as long as the hotkey should stay live; `deinit` unregisters.
final class GlobalHotkey {
  private var hotKeyRef: EventHotKeyRef?
  private var eventHandlerRef: EventHandlerRef?
  private let handler: () -> Void

  /// 'WRKR' — disambiguates our hot-key id from any other component's.
  private static let signature = OSType(0x5752_4B52)

  /// Register `carbonModifiers + keyCode`. `keyCode` is a virtual key code (e.g. `kVK_ISO_Section`)
  /// and `carbonModifiers` a Carbon modifier mask (e.g. `cmdKey`). Returns nil if registration
  /// fails (e.g. the combo is already claimed by another app), leaving the app otherwise unaffected.
  init?(keyCode: Int, carbonModifiers: Int, handler: @escaping () -> Void) {
    self.handler = handler

    // Carbon hot-key events arrive on the main run loop; the C trampoline can't capture context, so
    // we route through `userData` back to this instance.
    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
    let trampoline: EventHandlerUPP = { _, _, userData in
      guard let userData else { return OSStatus(eventNotHandledErr) }
      Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue().handler()
      return noErr
    }
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    guard
      InstallEventHandler(
        GetApplicationEventTarget(), trampoline, 1, &spec, selfPtr, &eventHandlerRef) == noErr
    else { return nil }

    let id = EventHotKeyID(signature: Self.signature, id: 1)
    guard
      RegisterEventHotKey(
        UInt32(keyCode), UInt32(carbonModifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef)
        == noErr
    else {
      RemoveEventHandler(eventHandlerRef)
      eventHandlerRef = nil
      return nil
    }
  }

  deinit {
    if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
  }

  /// ⌘ + § (the section key — `kVK_ISO_Section`, layout-independent). Keeps the Carbon key/modifier
  /// constants contained here so callers don't import Carbon. (Issue #13.)
  static func commandSection(handler: @escaping () -> Void) -> GlobalHotkey? {
    GlobalHotkey(keyCode: kVK_ISO_Section, carbonModifiers: cmdKey, handler: handler)
  }
}

import AppKit
import SwiftUI

/// The setup log shown as a panel floating *over* the detail pane while a setup script
/// runs on a freshly created workroom (issue #18). It overlays the main pane — faint,
/// decorative terminal output behind it sells the "over the terminal" look — and blocks
/// it: no terminal is created underneath until the user dismisses. The panel springs in on
/// appear (the faded backdrop fades up, the card scales up). There's no close button while
/// setup runs; once it finishes (success or failure) a "Dismiss" button appears —
/// dismissing clears the log, which lets the real terminal mount and open beneath the
/// fading panel. `@ObservedObject` keeps streaming updates scoped here.
struct SetupOverlay: View {
  @ObservedObject var session: ScriptLogSession
  var onDismiss: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Drives the enter animation. Flipped true in `onAppear` so the spring plays reliably
  /// regardless of how the containing detail pane was mounted (a `.transition` alone won't
  /// animate when the pane appears already-blocking from a fresh target selection).
  @State private var shown = false

  var body: some View {
    ZStack {
      // A fake CRT terminal behind the panel — purely cosmetic, so the floating card reads
      // as hovering over a terminal even though none is running yet (issue #18).
      FakeTerminalBackdrop()
        .opacity(shown ? 1 : 0)

      // A dim over the faux terminal so the green recedes and the card pops forward.
      Rectangle()
        .fill(Color.black.opacity(shown ? 0.25 : 0))
        .ignoresSafeArea()

      card
        .frame(maxWidth: 720, maxHeight: 520)
        .scaleEffect(shown ? 1 : 0.96)
        .opacity(shown ? 1 : 0)
        .padding(32)
    }
    .onAppear {
      guard !shown else { return }
      if reduceMotion {
        shown = true
      } else {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { shown = true }
      }
    }
  }

  private var card: some View {
    VStack(spacing: 0) {
      ScriptLogContent(session: session, onClose: nil)
      if session.isFinished {
        Divider()
        HStack {
          Spacer()
          Button("Dismiss", action: onDismiss)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("DismissSetup")
        }
        .padding(12)
      }
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: session.isFinished)
    .background(Color(nsColor: .windowBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
  }
}

/// A fake green-phosphor CRT terminal drawn behind `SetupOverlay`'s panel so it reads as
/// floating over a terminal. Purely decorative — no real terminal runs while setup is in
/// progress (issue #18). The content is an affectionate riff on the MU/TH/UR 6000 ("MOTHER")
/// interface from *Alien* (1979): dull phosphor green, scanlines, a slight defocus blur and a
/// faint flicker so it sits in the background. Static, non-interactive, hidden from a11y.
private struct FakeTerminalBackdrop: View {
  private enum Kind { case system, prompt, reply }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Dull phosphor green, à la a 1979 monochrome CRT well past its prime.
  private static let phosphor = Color(red: 0.34, green: 0.72, blue: 0.42)

  // MOTHER never had a prompt char; the "> " is our nod to a green terminal prompt.
  private static let script: [(Kind, String)] = [
    (.system, "WEYLAND-YUTANI CORP  —  MU/TH/UR 6000  ·  INTERFACE 2037 READY FOR INQUIRY"),
    (.reply, ""),
    (.reply, "USCSS NOSTROMO  ·  REG. 180924609  ·  COMMERCIAL TOWING VEHICLE, CLASS M"),
    (.reply, "CARGO: 20,000,000 TONS MINERAL ORE  ·  REFINERY UNDER TOW  ·  CREW 7"),
    (.reply, ""),
    (.prompt, "REQUEST WORKROOM STATUS REPORT"),
    (.reply, "WORKROOM ONLINE. ALL SYSTEMS NOMINAL. ENVIRONMENT PRESSURISED AND SEALED."),
    (.reply, "LIFE SUPPORT: GREEN   ·   DISK: GREEN   ·   NETWORK: GREEN   ·   VCS: JJ"),
    (.reply, ""),
    (.prompt, "WHAT IS THE NATURE OF THE SETUP SCRIPT"),
    (.reply, "ANALYZING SCRIPTS/WORKROOM_SETUP ..."),
    (.reply, "DEPENDENCIES RESOLVED. NODE_MODULES POPULATED. ENVIRONMENT STABLE."),
    (.reply, ""),
    (.prompt, "WHAT ARE MY CHANCES OF A CLEAN BUILD ON THE FIRST ATTEMPT"),
    (.reply, "DOES NOT COMPUTE."),
    (.reply, ""),
    (.system, "SPECIAL ORDER 937  —  SCIENCE OFFICER EYES ONLY  —  PRIORITY ONE"),
    (.reply, "BOOTSTRAP ENVIRONMENT AND RUN ALL PENDING MIGRATIONS TO COMPLETION."),
    (.reply, "SEED DATABASE. WARM CACHES. INSTALL GIT HOOKS. COMPILE ASSETS."),
    (.reply, "RETURN A WORKING WORKROOM FOR ANALYSIS. ALL OTHER CONSIDERATIONS SECONDARY."),
    (.reply, "CREW EXPENDABLE.   BRANCH EXPENDABLE.   STASH EXPENDABLE."),
    (.reply, ""),
    (.prompt, "git push --force origin main"),
    (.reply, "UNABLE TO COMPUTE. THE OPTION TO OVERRIDE EXPIRES IN T-MINUS 00:05:00."),
    (.reply, ""),
    (.prompt, "OVERRIDE  —  AUTHORIZATION RIPLEY 7-0-4-1-7-C"),
    (.reply, "DETONATION SEQUENCE ABORTED. HAVE A PLEASANT BUILD."),
    (.reply, ""),
    (.prompt, ""),
  ]

  var body: some View {
    Group {
      if reduceMotion {
        crt
      } else {
        // A faint flicker — the tube never sits perfectly still.
        TimelineView(.periodic(from: .now, by: 1.0 / 24.0)) { context in
          crt.opacity(Self.flickerOpacity(context.date))
        }
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private var crt: some View {
    ZStack {
      // Near-black with a faint green cast, like warmed-up phosphor.
      Color(red: 0.01, green: 0.035, blue: 0.02)

      VStack(alignment: .leading, spacing: 3) {
        ForEach(Array(Self.script.enumerated()), id: \.offset) { _, entry in
          line(entry.0, entry.1)
        }
        Spacer(minLength: 0)
      }
      .font(.system(.callout, design: .monospaced))
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(20)
      .shadow(color: Self.phosphor.opacity(0.35), radius: 1.5)  // soft phosphor glow
      .blur(radius: 0.6)  // a touch out of focus
    }
    .overlay(Scanlines())
    // Vignette: darken the edges/corners so it reads as a curved tube in the background.
    .overlay(
      EllipticalGradient(colors: [.clear, .black.opacity(0.45)], center: .center)
        .allowsHitTesting(false)
    )
  }

  @ViewBuilder
  private func line(_ kind: Kind, _ text: String) -> some View {
    switch kind {
    case .system:
      Text(text.isEmpty ? " " : text)
        .foregroundStyle(Self.phosphor)
        .fontWeight(.semibold)
    case .prompt:
      // A trailing empty prompt becomes the blinking-cursor line.
      Text(text.isEmpty ? "> █" : "> \(text)")
        .foregroundStyle(Self.phosphor)
    case .reply:
      Text(text.isEmpty ? " " : text)
        .foregroundStyle(Self.phosphor.opacity(0.5))
    }
  }

  /// Smooth pseudo-random flicker in ~[0.92, 1.0] — summed sines so it never repeats obviously.
  private static func flickerOpacity(_ date: Date) -> Double {
    let t = date.timeIntervalSinceReferenceDate
    let noise = (sin(t * 13.0) + sin(t * 27.3) + sin(t * 41.7)) / 3.0  // [-1, 1]
    return 0.92 + 0.08 * (noise * 0.5 + 0.5)
  }
}

/// Horizontal CRT scanlines: thin dark lines every few points, drawn over the terminal.
private struct Scanlines: View {
  var body: some View {
    Canvas { context, size in
      var y = 0.0
      while y < size.height {
        context.fill(
          Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
          with: .color(.black.opacity(0.2)))
        y += 3
      }
    }
    .allowsHitTesting(false)
  }
}

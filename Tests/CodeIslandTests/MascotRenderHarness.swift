import XCTest
import SwiftUI
@testable import CodeIsland

/// Offscreen render harness for mascot animation review (#15).
///
/// Not a pass/fail test of pixels — it renders each mascot's scenes at a
/// series of timeline instants into contact-sheet PNGs so animation changes
/// can be reviewed without launching the app. Sheets land in
/// `$MASCOT_SHEET_DIR` (skipped entirely when the variable is unset, so CI
/// never pays for it).
@MainActor
final class MascotRenderHarness: XCTestCase {

    func testRenderContactSheets() throws {
        guard let outDir = ProcessInfo.processInfo.environment["MASCOT_SHEET_DIR"] else {
            throw XCTSkip("MASCOT_SHEET_DIR not set — harness is opt-in")
        }
        let sources = (ProcessInfo.processInfo.environment["MASCOT_SHEET_SOURCES"] ?? "claude,codex")
            .split(separator: ",").map(String.init)
        let statuses: [(String, MascotAgentStatus)] = [
            ("idle", .idle),
            ("processing", .processing),
            ("waitingApproval", .waitingApproval),
            ("waitingQuestion", .waitingQuestion),
        ]
        // Sample instants chosen to catch blink/quirk windows, not just phase 0.
        let times: [Double] = [0.0, 0.6, 1.3, 2.1, 2.9, 3.6, 4.4, 5.2, 6.1, 7.0, 7.8, 8.5]

        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        for source in sources {
            for (label, status) in statuses {
                let sheet = MascotContactSheet(source: source, status: status, times: times)
                let renderer = ImageRenderer(content: sheet)
                renderer.scale = 4  // 4x for crisp pixel inspection
                guard let cgImage = renderer.cgImage else {
                    XCTFail("render failed for \(source)/\(label)"); continue
                }
                let rep = NSBitmapImageRep(cgImage: cgImage)
                guard let png = rep.representation(using: .png, properties: [:]) else {
                    XCTFail("png encode failed for \(source)/\(label)"); continue
                }
                let path = "\(outDir)/\(source)-\(label).png"
                try png.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}

/// One row of frames for a (source, status) pair, each frame rendered at a
/// fixed timeline instant via the static-frame path of MascotTimeline
/// (mascotAnimationsActive=false renders content(mascotStaticTime) once).
private struct MascotContactSheet: View {
    let source: String
    let status: MascotAgentStatus
    let times: [Double]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(times, id: \.self) { t in
                VStack(spacing: 2) {
                    mascot
                        .environment(\.mascotAnimationsActive, false)
                        .environment(\.mascotStaticTime, t)
                        .frame(width: 64, height: 64)
                        .background(Color.black)
                    Text(String(format: "%.1f", t))
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(6)
        .background(Color.black)
    }

    /// Direct routing (bypasses MascotView, which re-injects the live gate).
    @ViewBuilder
    private var mascot: some View {
        switch source {
        case "codex": DexView(status: status, size: 54)
        case "gemini": GeminiView(status: status, size: 54)
        case "cursor": CursorView(status: status, size: 54)
        case "trae": TraeView(status: status, size: 54)
        case "copilot": CopilotView(status: status, size: 54)
        case "qoder": QoderView(status: status, size: 54)
        case "droid": DroidView(status: status, size: 54)
        case "codebuddy": BuddyView(status: status, size: 54)
        case "stepfun": StepFunView(status: status, size: 54)
        case "opencode": OpenCodeView(status: status, size: 54)
        case "qwen": QwenView(status: status, size: 54)
        case "antigravity": AntiGravityView(status: status, size: 54)
        case "workbuddy": WorkBuddyView(status: status, size: 54)
        case "hermes": HermesView(status: status, size: 54)
        case "openclaw": OpenClawView(status: status, size: 54)
        case "kimi": KimiView(status: status, size: 54)
        case "pi": PiView(status: status, size: 54)
        case "cline": ClineView(status: status, size: 54)
        default: ClawdView(status: status, size: 54)
        }
    }
}

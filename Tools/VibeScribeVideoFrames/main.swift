// VibeScribeVideoFrames: renders the real VibeScribeCore views as transparent sprites and frame sequences
// for the launch video. Run from the repository root. See video/SPRITES.md.

import AppKit
import SwiftUI
@testable import VibeScribeCore

/// `command --name value --flag` arguments. The locale relaunch arguments are ignored.
struct Arguments {
    let command: String?
    private let options: [String: String]
    private let flags: Set<String>

    init(_ raw: [String]) {
        var list = raw
        // Drop "-AppleLocale en_US -AppleLanguages (en)" added by the relaunch.
        for key in ["-AppleLocale", "-AppleLanguages"] {
            while let i = list.firstIndex(of: key) {
                list.remove(at: i)
                if i < list.count { list.remove(at: i) }
            }
        }
        command = list.first.flatMap { $0.hasPrefix("-") ? nil : $0 }
        var options: [String: String] = [:]
        var flags: Set<String> = []
        var i = command == nil ? 0 : 1
        while i < list.count {
            let item = list[i]
            if item.hasPrefix("--") {
                if let eq = item.firstIndex(of: "=") {
                    options[String(item[..<eq])] = String(item[item.index(after: eq)...])
                } else if i + 1 < list.count, !list[i + 1].hasPrefix("--") {
                    options[item] = list[i + 1]
                    i += 1
                } else {
                    flags.insert(item)
                }
            }
            i += 1
        }
        self.options = options
        self.flags = flags
    }

    func value(_ name: String) -> String? { options[name] }
    func flag(_ name: String) -> Bool { flags.contains(name) || options[name] == "true" }

    func int(_ name: String) throws -> Int? {
        guard let text = options[name] else { return nil }
        guard let value = Int(text) else { throw ToolError("\(name) expects an integer, got “\(text)”") }
        return value
    }

    func double(_ name: String) throws -> Double? {
        guard let text = options[name] else { return nil }
        guard let value = Double(text) else { throw ToolError("\(name) expects a number, got “\(text)”") }
        return value
    }
}

let usage = """
VibeScribeVideoFrames: real VibeScribe UI as transparent PNGs for the launch video. Run from the repo root.

  sprites [--out DIR] [--only ID,PREFIX*,GROUP] [--list]
      Every sprite in video/spec.json (plus a few extras) into DIR (default video/build/sprites),
      each with a <id>.json sidecar, and DIR/manifest.json. --only re-renders a subset and merges the manifest.

  sequence --envelope FILE --out DIR [--state listening|handsfree|transcribing] [--layer pill|bars|statusitem]
           [--fps N] [--frames N | --duration S] [--t0 S] [--envelope-at S] [--started-at S]
           [--scale 4] [--quantize 30] [--status-rate 12] [--keycaps ⌥] [--badge en]
           [--prefix frame_] [--start-number 0]
      Numbered PNG frames (prefix%05d.png) of the animated overlay with SpectrumBars driven by the envelope,
      plus DIR/sequence.json. Frame i is t = i/fps s; level = envelope at t - envelope-at; bars time =
      floor((t0 + t) * 30) / 30; timer = floor(t - started-at).

  envelope --wav FILE --out FILE [--fps 60] [--buffer-frames 1024] [--tail 0.6]
      The app's own meter level (LevelMeter) for a recording, sampled at fps: {"fps", "levels", "kind": "level"}.

  test-envelope --out FILE [--fps 60] [--duration 4] [--lead 0.25] [--tail 0.6] [--hz 2.2]
      A synthetic sine envelope (through LevelMeter) for trying `sequence`.

  verify [--out DIR]
      Real SpectrumBars / OverlayPill vs the replica bars and clean plates; numbers and diff images in DIR
      (default video/build/verify).
"""

@MainActor
func main() -> Int32 {
    let args = Arguments(Array(CommandLine.arguments.dropFirst()))
    guard let command = args.command, command != "help" else {
        print(usage)
        return args.command == nil && !args.flag("--help") ? 2 : 0
    }

    // The settings pages format dates and numbers for the current locale; render them in en-US.
    if Locale.current.identifier != "en_US", !CommandLine.arguments.contains("-AppleLocale") {
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = Array(CommandLine.arguments.dropFirst()) + ["-AppleLocale", "en_US", "-AppleLanguages", "(en)"]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            print("Couldn’t relaunch in en-US (\(error.localizedDescription)); continuing with \(Locale.current.identifier).")
        }
    }

    NSApplication.shared.setActivationPolicy(.accessory)
    guard BarsMath.profile == SpectrumBars.profile else {
        print("error: SpectrumBars.profile changed; update BarsMath (and check speeds/phases in Spectrum.swift).")
        return 1
    }
    do {
        switch command {
        case "sprites": try runSprites(args)
        case "sequence": try runSequence(args)
        case "envelope": try runEnvelope(args)
        case "test-envelope": try runTestEnvelope(args)
        case "verify": try runVerify(args)
        default:
            print("Unknown command “\(command)”.\n\n\(usage)")
            return 2
        }
    } catch {
        print("error: \(error)")
        return 1
    }
    return 0
}

exit(MainActor.assumeIsolated { main() })

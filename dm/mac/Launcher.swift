// Mac app launcher: the settings window shown before the game starts, in the launcher's own process (launcher.c calls dm_mac_launcher before it starts the host). Its settings come from the
// app's Resources/dm/launcher.json (dm/games/settings.py with SETTINGS_PLATFORM=mac); the model and the rows are the iOS launcher's (dm/ios/Sources/LauncherSettings.swift, LauncherRow.swift),
// and so is the store: launcher.<VAR> in the app's preferences, which launcher.c reads when the window is not shown (docs/frontends.md, Saved choices). Basic settings (level basic) come
// first, the others under Advanced settings, each in the list's sections. Play puts the settings into this process's environment, which the host inherits; Quit and closing the window end the
// app without the game. "Show this window at launch" off: no window unless Option is held at launch, and launcher.c applies the saved choices. The window never takes focus by itself: an app
// opened in the background (open -g) keeps its window behind until the player switches to it
import AppKit
import QuartzCore
import SwiftUI

private func info(_ key: String) -> String? { Bundle.main.object(forInfoDictionaryKey: key) as? String }

/// Check for Updates: an app built by a script that can update it in place (install-ocarina-mac.sh --update) has that script's path in
/// ~/Library/Application Support/nxnative/<title ID>/update.path. --check-update says UPTODATE or AVAILABLE with a NEW line per change; --self-update pulls the checkout and
/// replaces the host, this launcher and the lists in the bundle while this window stays open (a running program's file can be replaced), printing PROGRESS <percent> <text>
/// lines. Then the app opens again as the new one and this process ends.
final class AppUpdater: ObservableObject {
    enum State: Equatable { case idle, checking, upToDate, available([String]), updating(Double, String), failed(String), restarting }
    static let shared = AppUpdater()
    @Published var state: State = .idle
    let script: String?

    init() {
        let path = NSHomeDirectory() + "/Library/Application Support/nxnative/\(info("DMTitleID") ?? "-")/update.path"
        let s = (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        script = FileManager.default.isReadableFile(atPath: s) ? s : nil
    }

    var busy: Bool { switch state { case .checking, .updating, .restarting: return true; default: return false } }

    func check() {
        guard script != nil else {
            state = .failed("This app does not know the folder it was built from. In the fork's folder, run once:\n./install-ocarina-mac.sh --update \"\(Bundle.main.bundlePath)\"")
            return
        }
        state = .checking
        var news: [String] = [], answer = ""
        run(["--check-update", Bundle.main.bundlePath], line: { l in
            if l.hasPrefix("NEW ") { news.append(String(l.dropFirst(4))) } else if l.hasPrefix("UPTODATE") || l.hasPrefix("AVAILABLE") { answer = l }
        }, done: { code, tail in
            self.state = code == 0 && answer.hasPrefix("UPTODATE") ? .upToDate : code == 0 && answer.hasPrefix("AVAILABLE") ? .available(news) : .failed(Self.reason(tail))
        })
    }

    func update() {
        state = .updating(0.01, "Starting")
        fputs("launcher: updating the app from \(script ?? "-")\n", stderr)
        run(["--self-update", Bundle.main.bundlePath, "--from-app", "--yes"], line: { l in
            guard l.hasPrefix("PROGRESS ") else { return }
            let f = l.dropFirst(9).split(separator: " ", maxSplits: 1)
            if f.count == 2, let v = Double(f[0]) { self.state = .updating(min(1, v / 100), String(f[1])) }
        }, done: { code, tail in
            if code != 0 { fputs("launcher: the update stopped (\(code))\n\(tail)\n", stderr); self.state = .failed(Self.reason(tail)); return }
            self.state = .restarting
            let again = Process()   // the new app, once this process is gone
            again.executableURL = URL(fileURLWithPath: "/bin/sh"); again.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
            again.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DM_") }   // open hands its environment on: without this launch's settings, which the new window would show as set at launch
            try? again.run()
            fputs("launcher: updated; opening the new version\n", stderr)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
        })
    }

    /// The script's own account of why it stopped (its STOPPED line and the advice under it), or its last lines
    static func reason(_ tail: String) -> String {
        let lines = tail.replacingOccurrences(of: "\u{1B}[31m", with: "").replacingOccurrences(of: "\u{1B}[1m", with: "").replacingOccurrences(of: "\u{1B}[0m", with: "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("PROGRESS ") }
        if let i = lines.lastIndex(where: { $0.hasPrefix("STOPPED:") }) { return lines[i...].prefix(4).joined(separator: "\n").replacingOccurrences(of: "STOPPED: ", with: "") }
        return lines.suffix(3).joined(separator: "\n")
    }

    private func run(_ args: [String], line: @escaping (String) -> Void, done: @escaping (Int32, String) -> Void) {
        guard let script else { return }
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = [script] + args
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DM_") }   // this launch's settings are not the build's
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")   // Homebrew's tools: an app opened from the Finder has the system's path only
        p.environment = env; p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
        let q = DispatchQueue(label: "update-output")
        var tail: [String] = []
        q.async {   // reads to the end of the output: the script and everything it started have closed it
            var rest = Data()
            while true {
                let d = pipe.fileHandleForReading.availableData
                if d.isEmpty { break }
                rest.append(d)
                while let i = rest.firstIndex(of: 10) {
                    let l = String(decoding: rest[rest.startIndex..<i], as: UTF8.self); rest.removeSubrange(rest.startIndex...i)
                    DispatchQueue.main.async { tail.append(l); if tail.count > 14 { tail.removeFirst() }; line(l) }
                }
            }
            p.waitUntilExit()
            DispatchQueue.main.async { done(p.terminationStatus, tail.joined(separator: "\n")) }
        }
        do { try p.run() } catch { DispatchQueue.main.async { done(-1, error.localizedDescription) } }
    }
}

/// The header's right side: the button, what it found, and the bar while the update runs
struct UpdateControl: View {
    @ObservedObject var u: AppUpdater

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            switch u.state {
            case .idle:
                Button("Check for Updates…") { u.check() }
            case .checking:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Looking for a new version…").foregroundStyle(.secondary) }
            case .upToDate:
                Text("This is the newest version.").foregroundStyle(.secondary)
            case .available(let news):
                Button("Update Now") { u.update() }
                Text(news.isEmpty ? "A new version is ready (about 3 minutes)." : "New: " + news.prefix(3).joined(separator: "; ") + (news.count > 3 ? "; …" : ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.trailing).frame(maxWidth: 300, alignment: .trailing)
                    .help(news.joined(separator: "\n"))
            case .updating(let v, let text):
                ProgressView(value: v).frame(width: 240)
                Text("\(text)  \(Int(v * 100)) %").font(.caption).foregroundStyle(.secondary)
            case .failed(let why):
                Text("The update did not finish.").foregroundStyle(.red)
                Text(why).font(.caption).foregroundStyle(.secondary).lineLimit(5).multilineTextAlignment(.trailing).frame(maxWidth: 300, alignment: .trailing).textSelection(.enabled)
                Button("Try Again") { u.check() }
            case .restarting:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Updated. Opening the new version…") }
            }
        }
    }
}

struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    let done: (Bool) -> Void
    let fit: (CGFloat) -> Void
    @AppStorage("window.show") private var show = true
    @AppStorage("window.advanced") private var advanced = false
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info("CFBundleName") ?? "Game").font(.title2.weight(.semibold))
                    Text("Version \(info("CFBundleShortVersionString") ?? "1.0")" + (info("DMCommit").map { " (\($0.prefix(9)))" } ?? "")).foregroundStyle(.secondary)
                }
                Spacer()
                UpdateControl(u: updater)
            }
            .padding([.horizontal, .top], 20)
            Form {
                settingSections(basic: true)
                CloudSavesSection()
                Section {
                    DisclosureGroup("Advanced settings", isExpanded: $advanced) {}
                }
                if advanced {
                    settingSections(basic: false)
                    Section {
                        Button("Reset to tested defaults") { m.reset() }
                            .disabled(!m.changed)
                    } footer: {
                        Text("Brings back all settings this game was tested with.")
                    }
                }
            }
            .formStyle(.grouped)
            .onScrollGeometryChange(for: CGFloat.self) {
                $0.contentSize.height + $0.contentInsets.top + $0.contentInsets.bottom - $0.containerSize.height
            } action: { _, extraHeight in
                fit(extraHeight)
            }
            HStack {
                Toggle("Show this window at launch", isOn: $show).toggleStyle(.checkbox)
                Spacer()
                Button("Quit") { done(false) }.disabled(updater.busy)
                Button("Play") { done(true) }.keyboardShortcut(.defaultAction).disabled(updater.busy)   // not while the update replaces the host
            }
            .padding(20)
        }
        .frame(minWidth: 520, idealWidth: 560)
    }

    @ViewBuilder private func settingSections(basic: Bool) -> some View {
        ForEach(m.sections(basic: basic), id: \.self) { section in
            let rows = m.rows(in: section, basic: basic)
            if !rows.isEmpty {
                Section(section) {
                    ForEach(rows) { SettingRow(s: $0, m: m) }
                }
            }
        }
    }
}

/// Cloud saves: a folder the save is synced through (dm/host/save_sync.h), the one the iPhone app picks in its launcher's Cloud saves section. It is kept in this app's
/// preferences as cloudSaves.folder, which launcher.c puts into DM_SAVE_SYNC before the host starts; a DM_SAVE_SYNC an env file or the launch environment set wins, and is shown here.
struct CloudSavesSection: View {
    @AppStorage("cloudSaves.folder") private var folder = ""
    private let fixed: String? = {
        let env = ProcessInfo.processInfo.environment
        let keys = ((env["DM_ENV_FILE_KEYS"] ?? "") + " " + (env["DM_ENV_LAUNCH_KEYS"] ?? "")).split(separator: " ")
        return keys.contains("DM_SAVE_SYNC") || env["DM_SAVE_SYNC"] != nil ? env["DM_SAVE_SYNC"] : nil
    }()

    var body: some View {
        Section {
            LabeledContent("Cloud saves") {
                Text(fixed.map { "\(Self.shown($0)) (env.txt)" } ?? (folder.isEmpty ? "Off" : Self.shown(folder)))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            if fixed == nil {
                HStack {
                    Button(folder.isEmpty ? "Choose a folder…" : "Choose a different folder…", action: choose)
                    if !folder.isEmpty { Button("Turn off") { folder = "" } }
                }
            }
        } footer: {
            Text("Choose the iCloud Drive folder the iPhone app uses for this game. The save comes in when the game starts and goes out after each save; a save that is replaced is kept in the save's -backups folder.")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.prompt = "Use for Cloud Saves"
        panel.message = "The folder the iPhone app chose in its launcher's Cloud saves"
        panel.directoryURL = URL(fileURLWithPath: folder.isEmpty ? Self.drive : folder)
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    static let drive = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"   // iCloud Drive, as the Finder shows it

    /// A path under iCloud Drive as the Finder and the Files app name it: iCloud Drive › Documents › dev › Zelda; any other path as it is
    static func shown(_ path: String) -> String {
        guard path == drive || path.hasPrefix(drive + "/") else { return path }
        return (["iCloud Drive"] + path.dropFirst(drive.count).split(separator: "/").map(String.init)).joined(separator: " › ")
    }
}

private final class Launcher: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model: LauncherModel
    var window: NSWindow?
    var play = false

    init(_ model: LauncherModel) { self.model = model }

    func applicationDidFinishLaunching(_ n: Notification) {
        let name = info("CFBundleName") ?? "Game"
        let menu = NSMenu(), item = NSMenuItem(), app = NSMenu()
        app.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        app.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = app; menu.addItem(item); NSApp.mainMenu = menu
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = name; w.isReleasedWhenClosed = false; w.delegate = self
        w.contentMinSize = NSSize(width: 520, height: 0)
        window = w
        if let screen = w.screen ?? NSScreen.main {
            w.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.midX - w.frame.width / 2, y: screen.visibleFrame.maxY))
        }
        let host = NSHostingView(rootView: LauncherView(m: model, done: { [weak self] in self?.finish($0) }, fit: { [weak self] in self?.fit($0) }))
        host.sizingOptions = []   // the Form's measured scroll content owns the height, including after collapse
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        // no activation and no ordering in front of another app's windows: LaunchServices activates an app opened from Finder or the Dock (applicationDidBecomeActive), open -g does not
        if NSApp.isActive { w.makeKeyAndOrderFront(nil) } else { w.orderBack(nil) }
    }
    func applicationDidBecomeActive(_ n: Notification) { window?.makeKeyAndOrderFront(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {   // ⌘Q, or a logout or restart: the app ends without the game (exit 0, as Quit)
        fputs("launcher: quit without starting the game\n", stderr)
        return .terminateNow   // not terminateCancel, which a logout or restart takes as a refusal and stops
    }
    func windowWillClose(_ n: Notification) { finish(false) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !AppUpdater.shared.busy }   // the update goes on without the window, and nothing would open the new version

    func fit(_ extraHeight: CGFloat) {
        guard let w = window, let screen = w.screen else { return }
        let frame = LauncherWindowLayout.fitted(w.frame, extraHeight: extraHeight, visible: screen.visibleFrame)
        if abs(frame.height - w.frame.height) > 0.5 { w.setFrame(frame, display: true) }
    }

    func finish(_ play: Bool) {
        guard let w = window else { return }
        window = nil; self.play = play
        // The main thread blocks in launcher.c's waitpid once run() returns, so the window must leave the screen now: no fade-out (it runs on later run-loop passes),
        // and dmMacLauncher flushes the order-out (AppKit commits it at the end of a pass). Without both, the window stayed on screen, not responding, until the game ended
        w.animationBehavior = .none
        w.delegate = nil; w.orderOut(nil)
        NSApp.stop(nil)
        NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: true)   // run returns at the next event
    }
}

enum LauncherWindowLayout {
    static func fitted(_ frame: NSRect, extraHeight: CGFloat, visible: NSRect) -> NSRect {
        let top = min(frame.maxY, visible.maxY)
        let height = min(frame.height + extraHeight, top - visible.minY)
        return NSRect(x: frame.minX, y: top - height, width: frame.width, height: height)
    }
}

// 1: Play (the window's settings are in the environment), 0: the player quit, 2: no window (no launcher.json, or "Show this window at launch" off): launcher.c applies the saved choices
@_cdecl("dm_mac_launcher")
public func dmMacLauncher() -> Int32 {
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("dm/launcher.json"), let data = try? Data(contentsOf: url) else { return 2 }
    guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr); return 2 }
    if (UserDefaults.standard.object(forKey: "window.show") as? Bool) == false && !NSEvent.modifierFlags.contains(.option) {
        fputs("launcher: settings window off (hold Option at launch to show it)\n", stderr)
        return 2
    }
    let model = LauncherModel(file.settings)
    let app = NSApplication.shared, launcher = Launcher(model)
    app.setActivationPolicy(.regular)
    app.delegate = launcher
    fputs("launcher: \(file.settings.count) settings shown\n", stderr)
    app.run()
    CATransaction.flush()   // finish's order-out
    app.setActivationPolicy(.prohibited)   // the host is the game's app from here on
    guard launcher.play else { fputs("launcher: quit without starting the game\n", stderr); return 0 }
    model.apply()
    return 1
}

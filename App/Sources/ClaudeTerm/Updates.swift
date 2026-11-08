import AppKit
import SwiftUI

// Updates come from the Homebrew tap: the formula's `tag:` is the released version, and
// `brew upgrade` builds and installs it. The check is one HTTPS GET of a public file.

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }
    static let author = "0xnicholasy"
    static let repo = URL(string: "https://github.com/0xnicholasy/claude-code-terminal")!
    static let formula = "0xnicholasy/tap/claudeterm"
    static let formulaURL = URL(string: "https://raw.githubusercontent.com/0xnicholasy/homebrew-tap/HEAD/Formula/claudeterm.rb")!
    static let upgradeCommand = "brew upgrade \(formula)"
}

enum Version {
    /// `tag: "v0.1.8"` in the formula -> "0.1.8".
    static func fromFormula(_ text: String) -> String? {
        guard let r = text.range(of: #"tag:\s*"v?([0-9]+(\.[0-9]+)*)""#, options: .regularExpression) else { return nil }
        let match = String(text[r])
        guard let q1 = match.firstIndex(of: "\"") else { return nil }
        return String(match[match.index(after: q1)...].dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "v"))
    }

    /// Numeric compare, missing parts count as 0: "0.1.10" > "0.1.9", "1.0" == "1.0.0".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

enum CodeSigning {
    /// First unexpired "Apple Development" identity hash in `security find-identity` output.
    static func identity(in output: String) -> String? {
        output.split(separator: "\n").first { $0.contains("\"Apple Development:") && !$0.contains("CSSMERR") }
            .flatMap { $0.split(separator: " ").dropFirst().first }.map(String.init)
    }
}

@MainActor
final class UpdateModel: ObservableObject {
    enum State: Equatable {
        case idle, checking, upToDate, available(String), installing, installed(String), failed(String)
    }

    static let autoCheckKey = "checkForUpdates"
    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?
    private var task: Task<Void, Never>?

    /// The app is a Homebrew install when it runs from the Cellar (/Applications holds a symlink to it).
    var isBrewInstall: Bool { Bundle.main.bundleURL.resolvingSymlinksInPath().path.contains("/Cellar/claudeterm/") }

    /// Checks at launch and then daily while automatic checks are on. `onFound` gets a newer version.
    func startAutomatic(onFound: @escaping @MainActor (String) -> Void) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                if UserDefaults.standard.object(forKey: Self.autoCheckKey) as? Bool ?? true, let self {
                    await self.check()
                    if case let .available(v) = self.state { onFound(v) }
                }
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }
    }

    func check() async {
        guard state != .checking, state != .installing else { return }
        state = .checking
        var request = URLRequest(url: AppInfo.formulaURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("ClaudeTerm/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let latest = Version.fromFormula(String(decoding: data, as: UTF8.self)) else {
            state = .failed("Could not reach GitHub.")
            return
        }
        lastChecked = Date()
        state = Version.isNewer(latest, than: AppInfo.version) ? .available(latest) : .upToDate
    }

    /// Runs `brew update` then `brew upgrade` for the formula; it builds from source, so it takes minutes.
    func install() async {
        guard case let .available(v) = state, isBrewInstall,
              let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.isExecutableFile) else { return }
        state = .installing
        let path = "PATH=" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        guard await ProcessRunner.run("/usr/bin/env", [path, brew, "update", "--quiet"], timeout: 300) != nil,
              await ProcessRunner.run("/usr/bin/env", [path, brew, "upgrade", AppInfo.formula], timeout: 1800) != nil else {
            state = .failed("brew upgrade failed. Run it in a terminal to see why: \(AppInfo.upgradeCommand)")
            return
        }
        await Self.signInstalled()
        state = .installed(v)
    }

    /// Homebrew's build sandbox cannot reach the login keychain, so the formula's build is signed ad
    /// hoc and macOS would drop ClaudeTerm's folder permissions. Re-sign the installed bundle with the
    /// user's Apple Development certificate, outside the sandbox. Without a certificate it stays ad hoc.
    static func signInstalled() async {
        guard let out = await ProcessRunner.run("/usr/bin/security", ["find-identity", "-p", "codesigning"]),
              let id = CodeSigning.identity(in: String(decoding: out, as: UTF8.self)) else { return }
        let app = URL(fileURLWithPath: "/opt/homebrew/opt/claudeterm/ClaudeTerm.app").resolvingSymlinksInPath().path
        _ = await ProcessRunner.run("/usr/bin/codesign", ["--force", "--deep", "--sign", id, app], timeout: 120)
    }

    /// Opens the new build once this process has exited. Panes come back through `claude --resume`.
    func relaunch() {
        let app = Bundle.main.bundleURL.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.3; done; open \"$0\"", app]
        try? p.run()
        NSApp.terminate(nil)
    }
}

struct AboutView: View {
    @ObservedObject var updates: UpdateModel
    @AppStorage(UpdateModel.autoCheckKey) private var autoCheck = true

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
                Text("ClaudeTerm").font(.title2).fontWeight(.semibold)
                Text("Version \(AppInfo.version)" + (AppInfo.build.isEmpty ? "" : " (\(AppInfo.build))"))
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("Author").foregroundStyle(.secondary)
                    Link(AppInfo.author, destination: URL(string: "https://github.com/\(AppInfo.author)")!)
                }
                GridRow {
                    Text("Source").foregroundStyle(.secondary)
                    Link("github.com/0xnicholasy/claude-code-terminal", destination: AppInfo.repo)
                }
                GridRow {
                    Text("Installed").foregroundStyle(.secondary)
                    Text(updates.isBrewInstall ? "Homebrew (\(AppInfo.formula))" : "Local build")
                }
            }
            .font(.callout)
            Divider()
            updateSection
        }
        .padding(24)
        .frame(width: 400)
    }

    @ViewBuilder private var updateSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                statusIcon
                Text(statusText).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer()
                actionButton
            }
            HStack {
                Toggle("Check for updates automatically", isOn: $autoCheck).toggleStyle(.checkbox).font(.callout)
                Spacer()
                if let t = updates.lastChecked {
                    Text("Checked \(t.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch updates.state {
        case .checking, .installing: ProgressView().controlSize(.small)
        case .available, .installed: Image(systemName: "arrow.down.circle.fill").foregroundStyle(Palette.accent)
        case .upToDate: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle: Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        switch updates.state {
        case .idle: "Not checked yet."
        case .checking: "Checking..."
        case .upToDate: "ClaudeTerm is up to date."
        case let .available(v):
            updates.isBrewInstall ? "Version \(v) is available."
                : "Version \(v) is available. Update with: \(AppInfo.upgradeCommand)"
        case .installing: "Building the update with Homebrew. This takes a few minutes."
        case let .installed(v): "Version \(v) is installed. Relaunch to use it."
        case let .failed(why): why
        }
    }

    @ViewBuilder private var actionButton: some View {
        switch updates.state {
        case .available where updates.isBrewInstall:
            Button("Install") { Task { await updates.install() } }.buttonStyle(.borderedProminent).tint(Palette.accent)
        case .installed:
            Button("Relaunch") { updates.relaunch() }.buttonStyle(.borderedProminent).tint(Palette.accent)
        case .checking, .installing:
            EmptyView()
        default:
            Button("Check Now") { Task { await updates.check() } }
        }
    }
}

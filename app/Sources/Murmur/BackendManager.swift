import Foundation
import AppKit

/// Spawns and supervises the local Python Kokoro backend.
@MainActor
final class BackendManager: ObservableObject {
    @Published var ready = false
    @Published var lastError: String?

    private var process: Process?
    let client = BackendClient()
    let port = 8765

    var modelsDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Murmur/models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Locate the repo (containing scripts/run_backend.sh). Checks the app
    /// bundle, an env override, then walks up from the executable.
    func repoRoot() -> URL? {
        if let env = ProcessInfo.processInfo.environment["MURMUR_REPO"] {
            return URL(fileURLWithPath: env)
        }
        // Bundled inside the app: Contents/Resources/repo
        if let res = Bundle.main.resourceURL {
            let bundled = res.appending(path: "repo")
            if FileManager.default.fileExists(atPath: bundled.appending(path: "scripts/run_backend.sh").path) {
                return bundled
            }
        }
        // Walk up from the executable looking for the script.
        var dir = Bundle.main.bundleURL
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appending(path: "scripts/run_backend.sh").path) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    /// Ensure the backend is up: reuse a running one, else launch it.
    func start() async {
        if let h = await client.health() {
            ready = h.model_loaded
            if !h.files_present { lastError = "Model files not installed." }
            if ready { return }
        }
        launchProcess()
        await waitForHealth()
    }

    private func launchProcess() {
        guard process == nil, let root = repoRoot() else {
            if repoRoot() == nil { lastError = "Backend scripts not found." }
            return
        }
        let script = root.appending(path: "scripts/run_backend.sh")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["MURMUR_MODELS_DIR"] = modelsDir.path
        env["MURMUR_PORT"] = String(port)
        // Ensure uv/homebrew on PATH for first-run venv creation.
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:\(NSHomeDirectory())/.local/bin"
        p.environment = env

        let logURL = FileManager.default.temporaryDirectory.appending(path: "murmur_backend.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let fh = try? FileHandle(forWritingTo: logURL) {
            p.standardOutput = fh
            p.standardError = fh
        }
        do { try p.run(); process = p }
        catch { lastError = "Failed to launch backend: \(error.localizedDescription)" }
    }

    private func waitForHealth() async {
        for _ in 0..<120 { // up to ~60s (covers first-run install/model load)
            if let h = await client.health() {
                ready = h.model_loaded
                lastError = h.files_present ? nil : "Model files not installed."
                if ready { return }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if !ready && lastError == nil { lastError = "Backend did not become ready in time." }
    }

    func stop() {
        process?.terminate()
        process = nil
    }
}

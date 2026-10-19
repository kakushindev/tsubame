#if os(macOS)
import Foundation

/// Finds the kubeconfig files macOS should offer to import.
///
/// PRD §9.1 asks for automatic `~/.kube/config` discovery on macOS, with manual
/// import staying equally visible. This is why the macOS target does not enable the
/// App Sandbox — see the sandbox decision in docs/IMPLEMENTATION_CHECKLIST.md.
///
/// `KUBECONFIG` may list several paths. How they merge is an open decision
/// (PRD §15), so this reports the paths it found and merges nothing.
struct KubeconfigLocator: KubeconfigDiscovery {
    private let environment: [String: String]
    private let homeDirectory: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    /// Candidate files in precedence order: `KUBECONFIG` entries first, then the
    /// default path. Only files that exist and are readable are returned.
    func discoveredConfigurations() -> [URL] {
        var candidates: [URL] = []
        if let paths = environment["KUBECONFIG"], !paths.isEmpty {
            candidates += paths
                .split(separator: ":")
                .map { URL(fileURLWithPath: String($0)).standardizedFileURL }
        }
        candidates.append(defaultConfigurationURL)

        var seen: Set<URL> = []
        return candidates.filter { url in
            guard seen.insert(url).inserted else { return false }
            return FileManager.default.isReadableFile(atPath: url.path)
        }
    }

    var defaultConfigurationURL: URL {
        homeDirectory.appending(path: ".kube/config").standardizedFileURL
    }
}
#endif

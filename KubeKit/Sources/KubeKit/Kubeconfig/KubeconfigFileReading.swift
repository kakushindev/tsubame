import Foundation
import KubeModels

/// Reads the files a kubeconfig points at.
///
/// A kubeconfig may name a CA bundle, a client certificate, a client key, or a
/// token file instead of inlining it. Those reads are a platform capability, not a
/// parsing detail, so they sit behind a protocol: a pasted kubeconfig has no
/// directory to resolve against, and iOS has no such files at all.
public protocol KubeconfigFileReading: Sendable {
    /// Reads a path named by a kubeconfig.
    ///
    /// `directory` is the folder holding the kubeconfig that named the path, because
    /// a relative path resolves against it — which is what client-go does, and what
    /// a user editing the file by hand expects.
    func contents(ofPath path: String, relativeTo directory: URL?) throws -> Data
}

public struct LocalKubeconfigFileReader: KubeconfigFileReading {
    public init() {}

    public func contents(ofPath path: String, relativeTo directory: URL?) throws -> Data {
        let url = try Self.resolve(path: path, relativeTo: directory)
        do {
            return try Data(contentsOf: url)
        } catch {
            throw KubernetesError.invalidConfiguration(
                reason: "The kubeconfig refers to \(url.path), which could not be read: "
                    + "\(error.localizedDescription)"
            )
        }
    }

    /// Expands `~` and resolves a relative path against the kubeconfig's directory.
    static func resolve(path: String, relativeTo directory: URL?) throws -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        guard let directory else {
            // Pasted text has no directory. Saying so beats resolving against the
            // process's working directory, which would read an unrelated file or
            // fail later as an unexplained TLS error.
            throw KubernetesError.invalidConfiguration(
                reason: "This kubeconfig refers to the file \(path) by a relative path. "
                    + "Relative paths can only be resolved when the kubeconfig is imported "
                    + "from a file, not pasted as text. Import the file itself, or replace "
                    + "the reference with inline data."
            )
        }
        return URL(fileURLWithPath: expanded, relativeTo: directory).standardizedFileURL
    }
}

/// Used where there are no local files to read: pasted text, and iOS.
public struct UnavailableKubeconfigFileReader: KubeconfigFileReading {
    public init() {}

    public func contents(ofPath path: String, relativeTo directory: URL?) throws -> Data {
        throw KubernetesError.invalidConfiguration(
            reason: "This kubeconfig refers to the file \(path), which this device cannot read. "
                + "Replace the reference with inline data, or set the cluster up manually."
        )
    }
}

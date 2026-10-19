import Foundation
import Yams
import KubeModels

/// Turns kubeconfig text into a `Kubeconfig`.
///
/// Declared as a protocol so the import flow can be tested without YAML fixtures,
/// and so a future `KUBECONFIG` merge strategy can replace the implementation
/// without touching the callers. Merge behavior across multiple `KUBECONFIG` paths
/// is an open decision (PRD §15) and is not implemented here.
public protocol KubeconfigParsing: Sendable {
    func parse(_ text: String) throws -> Kubeconfig
}

public struct KubeconfigParser: KubeconfigParsing {
    private let redactor: CredentialRedactor

    public init(redactor: CredentialRedactor = CredentialRedactor()) {
        self.redactor = redactor
    }

    public func parse(_ text: String) throws -> Kubeconfig {
        do {
            return try YAMLDecoder().decode(Kubeconfig.self, from: text)
        } catch {
            // A decoding error can quote the offending line, which may be a token.
            throw KubernetesError.invalidConfiguration(
                reason: redactor.redact(String(describing: error))
            )
        }
    }

    public func parse(contentsOf url: URL) throws -> Kubeconfig {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw KubernetesError.invalidConfiguration(reason: error.localizedDescription)
        }
        return try parse(text)
    }
}

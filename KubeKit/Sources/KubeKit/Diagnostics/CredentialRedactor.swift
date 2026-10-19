import Foundation

/// Removes credential material from any text that leaves the process boundary —
/// errors shown to the user, diagnostics, and anything written to a log.
///
/// This is deliberately separate from how the app displays Secret objects and logs:
/// those are cluster content the user is authorized to read and are shown as-is.
/// This type only covers the app's own credentials.
public struct CredentialRedactor: Sendable {
    public static let placeholder = "[redacted]"

    /// Header names whose values are never printed, in lowercase.
    private static let sensitiveHeaders: Set<String> = [
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie",
        "x-remote-user",
        "x-remote-group",
    ]

    /// Patterns for credential material that can appear inline in text.
    private let patterns: [NSRegularExpression]

    public init() {
        let sources = [
            // Bearer tokens, including the JWTs an OIDC flow returns.
            #"(?i)bearer\s+[A-Za-z0-9\-._~+/]+=*"#,
            // PEM blocks for client certificates and private keys.
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
            #"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----"#,
            // kubeconfig fields that carry base64 credential material.
            #"(?i)(client-key-data|client-certificate-data|token)\s*:\s*\S+"#,
        ]
        patterns = sources.compactMap { try? NSRegularExpression(pattern: $0) }
    }

    public func redact(_ text: String) -> String {
        patterns.reduce(text) { partial, pattern in
            pattern.stringByReplacingMatches(
                in: partial,
                range: NSRange(partial.startIndex..., in: partial),
                withTemplate: Self.placeholder
            )
        }
    }

    public func redact(headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { result, entry in
            result[entry.key] = Self.sensitiveHeaders.contains(entry.key.lowercased())
                ? Self.placeholder
                : redact(entry.value)
        }
    }
}

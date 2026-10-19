import Foundation

/// A proxy a cluster must be reached through, from a kubeconfig `proxy-url`.
///
/// Support differs by platform, and that difference has to be a failure rather than
/// a fallback: a user who configured a proxy and silently got a direct connection
/// has had a security expectation broken without being told.
public struct ProxyConfiguration: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case http
        case https
        case socks5
    }

    public let url: URL
    public let kind: Kind

    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http": self.kind = .http
        case "https": self.kind = .https
        case "socks5", "socks5h": self.kind = .socks5
        default: return nil
        }
        guard url.host != nil else { return nil }
        self.url = url
    }

    public init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
    }

    public var host: String? { url.host }

    public var port: Int {
        if let port = url.port { return port }
        switch kind {
        case .http: return 80
        case .https: return 443
        case .socks5: return 1080
        }
    }

    /// Whether this platform can honor the proxy.
    ///
    /// `URLSessionConfiguration.connectionProxyDictionary` carries SOCKS settings on
    /// macOS only, so a SOCKS proxy on iOS and iPadOS cannot be applied. Treating it
    /// as unsupported, and failing, is the honest answer; connecting directly is not.
    public func isSupported(on platform: HostPlatform) -> Bool {
        switch kind {
        case .http, .https:
            return true
        case .socks5:
            return platform == .macOS
        }
    }

    public var displayName: String {
        "\(kind.rawValue)://\(host ?? "?"):\(port)"
    }
}

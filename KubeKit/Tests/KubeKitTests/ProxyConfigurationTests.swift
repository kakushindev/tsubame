import Foundation
import Testing
import KubeModels
@testable import KubeKit

@Suite("ProxyConfiguration")
struct ProxyConfigurationTests {
    @Test("Reads the scheme a kubeconfig proxy-url can carry")
    func parsesSchemes() throws {
        #expect(ProxyConfiguration(url: URL(string: "http://proxy.internal:3128")!)?.kind == .http)
        #expect(ProxyConfiguration(url: URL(string: "https://proxy.internal")!)?.kind == .https)
        #expect(ProxyConfiguration(url: URL(string: "socks5://127.0.0.1:1080")!)?.kind == .socks5)
        // socks5h differs only in where DNS resolution happens, which is the proxy's
        // business, not ours.
        #expect(ProxyConfiguration(url: URL(string: "socks5h://127.0.0.1")!)?.kind == .socks5)
    }

    @Test("Refuses a URL it could not proxy through")
    func rejectsUnusableURLs() {
        #expect(ProxyConfiguration(url: URL(string: "ftp://proxy.internal")!) == nil)
        #expect(ProxyConfiguration(url: URL(string: "/just/a/path")!) == nil)
    }

    @Test("Defaults the port per scheme")
    func defaultsPorts() throws {
        #expect(ProxyConfiguration(url: URL(string: "http://p.internal")!)?.port == 80)
        #expect(ProxyConfiguration(url: URL(string: "https://p.internal")!)?.port == 443)
        #expect(ProxyConfiguration(url: URL(string: "socks5://p.internal")!)?.port == 1080)
        #expect(ProxyConfiguration(url: URL(string: "http://p.internal:8888")!)?.port == 8888)
    }

    @Test("SOCKS is macOS-only; HTTP proxies work everywhere")
    func reportsPlatformSupport() throws {
        let socks = try #require(ProxyConfiguration(url: URL(string: "socks5://p:1080")!))
        #expect(socks.isSupported(on: .macOS))
        #expect(!socks.isSupported(on: .iOS))

        let http = try #require(ProxyConfiguration(url: URL(string: "http://p:3128")!))
        #expect(http.isSupported(on: .macOS))
        #expect(http.isSupported(on: .iOS))
    }

    @Test("An unsupported proxy fails every request instead of connecting directly")
    func refusesRatherThanBypassing() async throws {
        let socks = try #require(ProxyConfiguration(url: URL(string: "socks5://127.0.0.1:1080")!))
        let transport = URLSessionTransport(
            serverURL: URL(string: "https://cluster.example:6443")!,
            credentialProvider: UnsupportedCredentialProvider(method: "none"),
            tls: .systemDefault,
            proxy: socks,
            platform: .iOS
        )

        await #expect(throws: KubernetesError.self) {
            _ = try await transport.send(APIRequest(method: .get, path: "/version"))
        }
        await #expect(throws: KubernetesError.self) {
            _ = try await transport.lines(for: APIRequest(method: .get, path: "/api/v1/pods"))
        }
    }
}

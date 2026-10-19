#if os(macOS)
import Foundation
import Testing
@testable import Tsubame

@Suite("KubeconfigLocator")
struct KubeconfigLocatorTests {
    private func makeHome() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "tsubame-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home.appending(path: ".kube"),
            withIntermediateDirectories: true
        )
        return home
    }

    @Test("Finds the default kubeconfig when it exists")
    func findsDefaultConfiguration() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appending(path: ".kube/config")
        try Data("apiVersion: v1".utf8).write(to: config)

        let locator = KubeconfigLocator(environment: [:], homeDirectory: home)

        #expect(locator.discoveredConfigurations() == [config.standardizedFileURL])
    }

    @Test("Returns nothing when no kubeconfig is present")
    func returnsNothingWhenAbsent() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let locator = KubeconfigLocator(environment: [:], homeDirectory: home)

        #expect(locator.discoveredConfigurations().isEmpty)
    }

    @Test("Lists KUBECONFIG paths before the default and drops duplicates")
    func prefersEnvironmentPaths() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let defaultConfig = home.appending(path: ".kube/config")
        let extraConfig = home.appending(path: ".kube/other")
        try Data("apiVersion: v1".utf8).write(to: defaultConfig)
        try Data("apiVersion: v1".utf8).write(to: extraConfig)

        let locator = KubeconfigLocator(
            environment: ["KUBECONFIG": "\(extraConfig.path):\(defaultConfig.path)"],
            homeDirectory: home
        )

        #expect(
            locator.discoveredConfigurations()
                == [extraConfig.standardizedFileURL, defaultConfig.standardizedFileURL]
        )
    }
}
#endif

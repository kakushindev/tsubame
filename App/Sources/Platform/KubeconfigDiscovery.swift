import Foundation

/// Finds kubeconfig files the app can offer to import without a file picker.
///
/// It is a protocol because the answer is a platform fact, not a setting: macOS has
/// a local kubeconfig to discover and iOS and iPadOS do not (PRD §10). Feature code
/// asks for the list and renders what it gets, with no `#if` of its own.
protocol KubeconfigDiscovery: Sendable {
    func discoveredConfigurations() -> [URL]
}

/// Used on iOS and iPadOS, where there is no local kubeconfig and no `kubectl`.
/// The UI must not imply otherwise, so this reports nothing rather than guessing.
struct NoKubeconfigDiscovery: KubeconfigDiscovery {
    func discoveredConfigurations() -> [URL] { [] }
}

#if os(macOS)
import Foundation
import KubeKit
import KubeModels

/// Runs a kubeconfig exec credential plugin as a subprocess.
///
/// Its own target so that spawning a process stays out of KubeKit, and so iOS
/// cannot reach `Process` at all: there the app uses `DecliningExecApproval` and
/// says plainly that plugins are unsupported (PRD §10).
public struct ProcessExecPluginRunner: ExecPluginRunning {
    public init() {}

    public func run(_ invocation: ExecPluginInvocation) async throws -> ExecCredentialStatus {
        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        // The plugin's own environment, plus what the kubeconfig named. A plugin
        // that inherits nothing cannot find its own configuration.
        process.environment = ProcessInfo.processInfo.environment
            .merging(invocation.environment) { _, fromKubeconfig in fromKubeconfig }

        let output = Pipe()
        let errors = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input

        try process.run()

        if let data = invocation.standardInput {
            try? input.fileHandleForWriting.write(contentsOf: data)
        }
        try? input.fileHandleForWriting.close()

        // Read before waiting: a plugin writing more than a pipe buffer would block
        // forever if we waited for exit first.
        let outputData = try await read(output, errors: errors, process: process, timeout: invocation.timeout)

        guard process.terminationStatus == 0 else {
            let message = String(decoding: outputData.errors, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw KubernetesError.invalidConfiguration(
                reason: "\(invocation.executableURL.lastPathComponent) exited with code "
                    + "\(process.terminationStatus)."
                    + (message.isEmpty ? "" : " \(message)")
            )
        }

        do {
            return try JSONDecoder().decode(ExecCredentialStatus.self, from: outputData.output)
        } catch {
            throw KubernetesError.decodingFailure(
                reason: "\(invocation.executableURL.lastPathComponent) did not return a "
                    + "credential this app understands."
            )
        }
    }

    private func read(
        _ output: Pipe,
        errors: Pipe,
        process: Process,
        timeout: TimeInterval
    ) async throws -> (output: Data, errors: Data) {
        let reader = Task.detached {
            let out = output.fileHandleForReading.readDataToEndOfFile()
            let err = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (out, err)
        }
        let watchdog = Task.detached {
            try await Task.sleep(for: .seconds(timeout))
            // A plugin waiting on a prompt that will never come would otherwise
            // hold the view open indefinitely.
            if process.isRunning { process.terminate() }
        }
        defer { watchdog.cancel() }

        let result = await reader.value
        if process.terminationReason == .uncaughtSignal {
            throw KubernetesError.invalidConfiguration(
                reason: "\(process.executableURL?.lastPathComponent ?? "The credential plugin") "
                    + "did not finish within \(Int(timeout)) seconds and was stopped."
            )
        }
        return result
    }
}
#endif

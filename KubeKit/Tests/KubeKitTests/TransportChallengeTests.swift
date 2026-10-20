import Foundation
import Testing
import KubeModels
@testable import KubeKit

@Suite("Transport authentication challenges")
struct TransportChallengeTests {
    @Test("An unsolicited URLSession cancellation is a visible connection failure")
    func unsolicitedCancellation() {
        #expect(!URLSessionTransport.isCancellation(URLError(.cancelled)))
        #expect(!URLSessionTransport.isCancellation(CancellationError()))
    }

    @Test("Cancellation of the owning task remains cancellation")
    func owningTaskCancellation() async {
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return URLSessionTransport.isCancellation(URLError(.cancelled))
        }.value
        #expect(result)
    }
    private func transport(tls: TLSConfiguration = .systemDefault) -> URLSessionTransport {
        URLSessionTransport(
            serverURL: URL(string: "https://cluster.example:6443")!,
            credentialProvider: UnsupportedCredentialProvider(method: "none"),
            tls: tls
        )
    }

    private func challenge(_ method: String) -> URLAuthenticationChallenge {
        URLAuthenticationChallenge(
            protectionSpace: URLProtectionSpace(
                host: "cluster.example", port: 6443, protocol: "https",
                realm: nil, authenticationMethod: method
            ),
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: NoopChallengeSender()
        )
    }

    @Test("Task-level challenges are answered, not left to default handling")
    func answersTaskLevelChallenges() async throws {
        // `bytes(for:)` — every watch and log stream — delivers challenges to the
        // task-level method. While only the session-level one existed, streams fell
        // back to default handling and rejected every private certificate
        // authority, while ordinary requests on the same transport succeeded.
        let subject = transport()
        let session = URLSession(configuration: .ephemeral)

        let (taskDisposition, _) = await subject.urlSession(
            session,
            task: session.dataTask(with: URL(string: "https://cluster.example:6443")!),
            didReceive: challenge(NSURLAuthenticationMethodClientCertificate)
        )
        let (sessionDisposition, _) = await subject.urlSession(
            session, didReceive: challenge(NSURLAuthenticationMethodClientCertificate)
        )
        // Both entry points must reach the same decision; one transport cannot
        // answer two ways depending on which call made the request.
        #expect(taskDisposition == sessionDisposition)
    }

    @Test("A method the transport does not handle falls through to the system")
    func passesOtherMethodsThrough() async throws {
        let subject = transport()
        let session = URLSession(configuration: .ephemeral)
        let (disposition, credential) = await subject.urlSession(
            session, didReceive: challenge(NSURLAuthenticationMethodHTTPBasic)
        )
        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
    }
}

/// `URLAuthenticationChallenge` requires a sender; nothing here uses it.
private final class NoopChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

import Foundation
import Security
import KubeModels

/// Decides whether to trust a cluster's server certificate.
///
/// Clusters commonly use a private CA, so the kubeconfig's
/// `certificate-authority-data` is installed as an additional anchor. System trust
/// still applies; an explicitly insecure connection is the only way to skip the
/// check, and it is never the default.
struct ServerTrustEvaluator: Sendable {
    private let configuration: TLSConfiguration

    init(configuration: TLSConfiguration) {
        self.configuration = configuration
    }

    func evaluate(
        _ challenge: URLAuthenticationChallenge
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        if configuration.allowsInsecureConnections {
            return (.useCredential, URLCredential(trust: trust))
        }
        guard let anchorData = configuration.certificateAuthorityData else {
            return (.performDefaultHandling, nil)
        }
        guard applyAnchors(anchorData, to: trust) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }

    /// Installs the kubeconfig CA as the anchor set. `anchorCertificatesOnly` stays
    /// false so a cluster behind a publicly trusted certificate still validates.
    private func applyAnchors(_ pemData: Data, to trust: SecTrust) -> Bool {
        let certificates = Self.certificates(fromPEM: pemData)
        guard !certificates.isEmpty else { return false }
        guard SecTrustSetAnchorCertificates(trust, certificates as CFArray) == errSecSuccess else {
            return false
        }
        return SecTrustSetAnchorCertificatesOnly(trust, false) == errSecSuccess
    }

    /// Splits a PEM bundle into certificates. A kubeconfig CA field may hold a
    /// chain, and `SecCertificateCreateWithData` takes one DER body at a time.
    static func certificates(fromPEM pemData: Data) -> [SecCertificate] {
        guard let pem = String(data: pemData, encoding: .utf8) else { return [] }
        let header = "-----BEGIN CERTIFICATE-----"
        let footer = "-----END CERTIFICATE-----"
        return pem.components(separatedBy: header)
            .dropFirst()
            .compactMap { block -> SecCertificate? in
                guard let end = block.range(of: footer) else { return nil }
                let base64 = block[block.startIndex..<end.lowerBound]
                    .components(separatedBy: .whitespacesAndNewlines)
                    .joined()
                guard let der = Data(base64Encoded: base64) else { return nil }
                return SecCertificateCreateWithData(nil, der as CFData)
            }
    }
}

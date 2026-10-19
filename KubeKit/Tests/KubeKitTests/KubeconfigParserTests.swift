import Foundation
import Testing
import KubeModels
@testable import KubeKit

@Suite("KubeconfigParser")
struct KubeconfigParserTests {
    private let sample = """
    apiVersion: v1
    kind: Config
    current-context: dev
    clusters:
      - name: dev-cluster
        cluster:
          server: https://dev.example.com:6443
          certificate-authority-data: Zm9v
      - name: prod-cluster
        cluster:
          server: https://prod.example.com:6443
          insecure-skip-tls-verify: true
    contexts:
      - name: dev
        context:
          cluster: dev-cluster
          user: dev-user
      - name: prod
        context:
          cluster: prod-cluster
          user: prod-user
          namespace: platform
    users:
      - name: dev-user
        user:
          token: sample-token-value
      - name: prod-user
        user:
          exec:
            apiVersion: client.authentication.k8s.io/v1beta1
            command: aws
            args: ["eks", "get-token"]
    """

    @Test("Parses clusters, contexts, and users")
    func parsesDocument() throws {
        let config = try KubeconfigParser().parse(sample)

        #expect(config.currentContext == "dev")
        #expect(config.clusters.count == 2)
        #expect(config.cluster(named: "dev-cluster")?.server == "https://dev.example.com:6443")
        #expect(config.cluster(named: "prod-cluster")?.insecureSkipTLSVerify == true)
        #expect(config.context(named: "prod")?.namespace == "platform")
        #expect(config.user(named: "dev-user")?.token == "sample-token-value")
        #expect(config.user(named: "prod-user")?.exec?.command == "aws")
        #expect(config.user(named: "prod-user")?.exec?.args == ["eks", "get-token"])
    }

    @Test("Summarizes contexts and defaults the namespace to default")
    func summarizesContexts() throws {
        let summaries = try KubeconfigParser().parse(sample).contextSummaries

        #expect(summaries.count == 2)
        let dev = try #require(summaries.first { $0.contextName == "dev" })
        #expect(dev.isCurrent)
        #expect(dev.namespace == ClusterConnection.defaultNamespaceName)
        #expect(dev.server == "https://dev.example.com:6443")

        let prod = try #require(summaries.first { $0.contextName == "prod" })
        #expect(prod.isCurrent == false)
        #expect(prod.namespace == "platform")
    }

    @Test("Reports malformed YAML as an invalid configuration")
    func reportsMalformedDocument() {
        #expect(throws: KubernetesError.self) {
            try KubeconfigParser().parse("clusters: [this is: not valid")
        }
    }
}

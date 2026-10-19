import Foundation
import KubeModels

/// Shared names, grouping and symbols for navigation and resource headers.
enum ResourceKindPresentation {
    enum Category: String, CaseIterable, Identifiable {
        case workloads = "Workloads", networking = "Networking", configuration = "Configuration"
        case storage = "Storage", access = "Access", cluster = "Cluster", custom = "Custom resources"
        var id: String { rawValue }
    }

    static func category(_ resource: DiscoveredResource) -> Category {
        switch resource.kind {
        case "Pod", "Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob", "ReplicaSet", "ReplicationController": .workloads
        case "Service", "Endpoints", "EndpointSlice", "Ingress", "IngressClass", "NetworkPolicy": .networking
        case "ConfigMap", "Secret", "ResourceQuota", "LimitRange", "HorizontalPodAutoscaler", "PodDisruptionBudget": .configuration
        case "PersistentVolume", "PersistentVolumeClaim", "StorageClass", "CSIDriver", "CSINode", "VolumeAttachment": .storage
        case "Role", "RoleBinding", "ClusterRole", "ClusterRoleBinding", "ServiceAccount": .access
        case "Node", "Namespace", "Event", "CustomResourceDefinition", "APIService", "PriorityClass": .cluster
        default: .custom
        }
    }

    static func name(_ resource: DiscoveredResource) -> String {
        switch resource.kind {
        case "Ingress": "Ingresses"
        case "Endpoints": "Endpoints"
        case "StorageClass": "Storage classes"
        case "PriorityClass": "Priority classes"
        default: resource.kind + "s"
        }
    }

    static func symbol(_ resource: DiscoveredResource) -> String {
        switch resource.kind {
        case "Pod": "shippingbox"
        case "Deployment": "square.stack.3d.up"
        case "StatefulSet", "DaemonSet": "square.3.layers.3d"
        case "Job": "checklist"
        case "CronJob": "clock"
        case "Service", "Ingress": "network"
        case "ConfigMap": "doc.text"
        case "Secret": "key"
        case "Namespace": "folder"
        case "Event": "bolt.horizontal.circle"
        case "Node": "server.rack"
        default:
            switch category(resource) {
            case .storage: "externaldrive"
            case .access: "person.badge.key"
            case .networking: "network"
            default: "square.stack"
            }
        }
    }
}

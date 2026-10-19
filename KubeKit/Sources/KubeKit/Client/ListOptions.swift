import Foundation

/// Query parameters shared by list and watch requests.
public struct ListOptions: Hashable, Sendable {
    public var labelSelector: String?
    public var fieldSelector: String?
    /// Page size. Large collections are paged rather than fetched whole.
    public var limit: Int?
    /// The `continue` token from the previous page.
    public var continueToken: String?
    /// Where a watch resumes from. `nil` starts from the server's current state.
    public var resourceVersion: String?
    /// Asks the server for periodic bookmarks so a quiet watch can still advance
    /// its `resourceVersion` and avoid a `410 Gone` on reconnect.
    public var allowWatchBookmarks: Bool
    /// How long the server holds a watch open before closing it cleanly.
    public var timeoutSeconds: Int?

    public init(
        labelSelector: String? = nil,
        fieldSelector: String? = nil,
        limit: Int? = 500,
        continueToken: String? = nil,
        resourceVersion: String? = nil,
        allowWatchBookmarks: Bool = true,
        timeoutSeconds: Int? = nil
    ) {
        self.labelSelector = labelSelector
        self.fieldSelector = fieldSelector
        self.limit = limit
        self.continueToken = continueToken
        self.resourceVersion = resourceVersion
        self.allowWatchBookmarks = allowWatchBookmarks
        self.timeoutSeconds = timeoutSeconds
    }

    func queryItems(watching: Bool) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let labelSelector { items.append(URLQueryItem(name: "labelSelector", value: labelSelector)) }
        if let fieldSelector { items.append(URLQueryItem(name: "fieldSelector", value: fieldSelector)) }
        if let resourceVersion { items.append(URLQueryItem(name: "resourceVersion", value: resourceVersion)) }
        if watching {
            items.append(URLQueryItem(name: "watch", value: "1"))
            if allowWatchBookmarks {
                items.append(URLQueryItem(name: "allowWatchBookmarks", value: "true"))
            }
            if let timeoutSeconds {
                items.append(URLQueryItem(name: "timeoutSeconds", value: String(timeoutSeconds)))
            }
        } else {
            if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
            if let continueToken { items.append(URLQueryItem(name: "continue", value: continueToken)) }
        }
        return items
    }
}

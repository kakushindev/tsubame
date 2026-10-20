import Foundation

/// A column a CRD asks to be shown for its resources.
///
/// This is how a custom resource gets a useful table without the app knowing
/// anything about it: the definition names the columns and where to read them.
public struct PrinterColumn: Hashable, Sendable, Codable {
    public enum ColumnType: String, Hashable, Sendable, Codable {
        case string, integer, number, boolean, date
    }

    public let name: String
    public let type: ColumnType
    public let description: String?
    public let jsonPath: String
    /// 0 is shown by default; higher is detail a wide listing would add.
    public let priority: Int

    public init(
        name: String, type: ColumnType = .string, description: String? = nil,
        jsonPath: String, priority: Int = 0
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.jsonPath = jsonPath
        self.priority = priority
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        type = (try? c.decodeIfPresent(ColumnType.self, forKey: .type)) as? ColumnType ?? .string
        description = try c.decodeIfPresent(String.self, forKey: .description)
        jsonPath = try c.decodeIfPresent(String.self, forKey: .jsonPath) ?? ""
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case name, type, description, jsonPath, priority
    }

    /// Reads this column's value out of an object.
    ///
    /// Only the dotted-field and numeric-index subset of JSONPath is supported —
    /// `.status.phase`, `.spec.items[0].name`. Filters, wildcards and slices
    /// return nil and the column renders empty, which is the honest outcome: a
    /// half-evaluated path would show a confidently wrong value.
    public func value(in object: JSONValue) -> String? {
        guard let value = Self.evaluate(jsonPath, in: object) else { return nil }
        return Self.describe(value, as: type)
    }

    static func evaluate(_ path: String, in object: JSONValue) -> JSONValue? {
        var trimmed = path
        if trimmed.hasPrefix("$") { trimmed.removeFirst() }
        guard !trimmed.contains("*"), !trimmed.contains("?"), !trimmed.contains("..") else {
            return nil
        }
        var current = object
        for rawSegment in trimmed.split(separator: ".") {
            var segment = String(rawSegment)
            var indices: [Int] = []
            // Pull any [n] suffixes off the field name.
            while let open = segment.lastIndex(of: "["), segment.hasSuffix("]") {
                let inside = segment[segment.index(after: open)..<segment.index(before: segment.endIndex)]
                guard let index = Int(inside) else { return nil }
                indices.insert(index, at: 0)
                segment = String(segment[segment.startIndex..<open])
            }
            if !segment.isEmpty {
                guard let next = current.objectValue?[segment] else { return nil }
                current = next
            }
            for index in indices {
                guard let array = current.arrayValue, array.indices.contains(index) else { return nil }
                current = array[index]
            }
        }
        return current
    }

    static func describe(_ value: JSONValue, as type: ColumnType) -> String? {
        switch value {
        case .null: return nil
        case .string(let text):
            // A date column holds an RFC 3339 string; show it as an age the way
            // every other column of times in this app does.
            guard type == .date, let date = RFC3339.date(from: text) else { return text }
            return date.formatted(.relative(presentation: .numeric))
        case .integer(let number): return String(number)
        case .number(let number):
            return number == number.rounded() ? String(Int(number)) : String(number)
        case .bool(let flag): return flag ? "true" : "false"
        case .array(let items): return items.isEmpty ? nil : "\(items.count)"
        case .object: return nil
        }
    }
}

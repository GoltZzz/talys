import Foundation

/// A value written into config.toml by the settings window.
public enum TOMLValue: Equatable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)

    var literal: String {
        switch self {
        case .string(let s): return TOMLValue.quote(s)
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d):
            // Keep the decimal point so the field still decodes as a float.
            let rounded = (d * 100).rounded() / 100
            return rounded == rounded.rounded() ? String(format: "%.1f", rounded) : String(rounded)
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default: out.append(ch)
            }
        }
        return out + "\""
    }
}

/// Line-level editor for config.toml that changes only the lines it has to, so comments, ordering and
/// alignment the user wrote by hand survive edits made from the settings window.
public struct ConfigFile {
    public private(set) var lines: [String]

    public init(text: String) {
        lines = text.components(separatedBy: "\n")
    }

    public static func load(from url: URL = ConfigManager.configURL) -> ConfigFile {
        ConfigFile(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    public var text: String { lines.joined(separator: "\n") }

    public func save(to url: URL = ConfigManager.configURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Tables

    /// Sets `key = value` under `[section]`, keeping any trailing comment at its original column.
    /// Adds the key after the section's last entry, or appends the section, when missing.
    public mutating func set(_ section: String, _ key: String, _ value: TOMLValue) {
        if let i = keyLine(section, key) {
            lines[i] = Self.replacingValue(in: lines[i], with: value.literal)
            return
        }
        let newLine = "\(Self.bareKey(key)) = \(value.literal)"
        if let range = tableRange(section) {
            lines.insert(newLine, at: lastEntry(in: range).map { $0 + 1 } ?? range.lowerBound + 1)
        } else {
            appendBlock(["[\(section)]", newLine])
        }
    }

    public mutating func remove(_ section: String, _ key: String) {
        if let i = keyLine(section, key) { lines.remove(at: i) }
    }

    // MARK: - Arrays of tables

    /// Replaces every `[[name]]` block with `entries`, written where the first block was.
    /// Commented-out examples between or after the blocks are left alone.
    public mutating func replaceArray(_ name: String, with entries: [[(String, TOMLValue)]]) {
        let blocks = arrayBlocks(name)
        let rendered: [String] = entries.enumerated().flatMap { index, entry -> [String] in
            let body = ["[[\(name)]]"] + entry.map { "\(Self.bareKey($0.0)) = \($0.1.literal)" }
            return index < entries.count - 1 ? body + [""] : body
        }

        guard let first = blocks.first else {
            if !rendered.isEmpty { appendBlock(rendered) }
            return
        }
        for block in blocks.dropFirst().reversed() {
            lines.removeSubrange(block)
            // Drop the blank line that separated the removed block from the one before it.
            if block.lowerBound > 0, block.lowerBound - 1 < lines.count,
               lines[block.lowerBound - 1].trimmingCharacters(in: .whitespaces).isEmpty,
               block.lowerBound >= lines.count || lines[block.lowerBound].trimmingCharacters(in: .whitespaces).isEmpty {
                lines.remove(at: block.lowerBound - 1)
            }
        }
        lines.replaceSubrange(first, with: rendered)
    }

    // MARK: - Scanning

    private enum Header: Equatable {
        case table(String)
        case array(String)
    }

    private static func header(_ raw: String) -> Header? {
        let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("[["), line.hasSuffix("]]") {
            return .array(line.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces))
        }
        if line.hasPrefix("["), line.hasSuffix("]") {
            return .table(line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Lines owned by `[section]`: its header up to the next header.
    private func tableRange(_ section: String) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { Self.header($0) == .table(section) }) else { return nil }
        let end = lines[(start + 1)...].firstIndex { Self.header($0) != nil } ?? lines.count
        return start..<end
    }

    private func keyLine(_ section: String, _ key: String) -> Int? {
        guard let range = tableRange(section) else { return nil }
        return range.dropFirst().first { Self.key(of: lines[$0]) == key }
    }

    private func lastEntry(in range: Range<Int>) -> Int? {
        range.dropFirst().last { Self.key(of: lines[$0]) != nil }
    }

    /// Each `[[name]]` block runs from its header to its last key line, leaving trailing
    /// blank lines and comments (such as commented-out examples) outside it.
    private func arrayBlocks(_ name: String) -> [Range<Int>] {
        var blocks: [Range<Int>] = []
        var i = 0
        while i < lines.count {
            guard Self.header(lines[i]) == .array(name) else { i += 1; continue }
            var end = i + 1
            var j = i + 1
            while j < lines.count, Self.header(lines[j]) == nil {
                if Self.key(of: lines[j]) != nil { end = j + 1 }
                j += 1
            }
            blocks.append(i..<end)
            i = end
        }
        return blocks
    }

    private mutating func appendBlock(_ block: [String]) {
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if !lines.isEmpty { lines.append("") }
        lines += block
        lines.append("")
    }

    // MARK: - Line parsing

    /// The key of a `key = value` line, unquoted; nil for comments, headers and blank lines.
    static func key(of raw: String) -> String? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("["),
              let eq = line.firstIndex(of: "=") else { return nil }
        var key = line[..<eq].trimmingCharacters(in: .whitespaces)
        if key.count >= 2, let q = key.first, q == "\"" || q == "'", key.last == q {
            key = String(key.dropFirst().dropLast())
        }
        return key
    }

    private static func bareKey(_ key: String) -> String {
        let bare = key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return bare ? key : TOMLValue.quote(key)
    }

    /// Where the value's text ends on a `key = value` line, skipping over `#` inside strings.
    private static func valueEnd(in line: String, from start: String.Index) -> String.Index {
        var i = start
        while i < line.endIndex, line[i] == " " || line[i] == "\t" { i = line.index(after: i) }
        guard i < line.endIndex else { return i }

        let quote = line[i]
        if quote == "\"" || quote == "'" {
            var j = line.index(after: i)
            while j < line.endIndex {
                if quote == "\"", line[j] == "\\" {
                    j = line.index(after: j)
                    if j < line.endIndex { j = line.index(after: j) }
                    continue
                }
                if line[j] == quote { return line.index(after: j) }
                j = line.index(after: j)
            }
            return line.endIndex
        }
        let hash = line[i...].firstIndex(of: "#") ?? line.endIndex
        var end = hash
        while end > i, line[line.index(before: end)] == " " || line[line.index(before: end)] == "\t" {
            end = line.index(before: end)
        }
        return end
    }

    private static func stripComment(_ line: String) -> String {
        guard let hash = line.firstIndex(of: "#") else { return line }
        return String(line[..<hash])
    }

    static func replacingValue(in line: String, with literal: String) -> String {
        guard let eq = line.firstIndex(of: "=") else { return line }
        let prefix = line[...eq]
        let end = valueEnd(in: line, from: line.index(after: eq))
        let rest = line[end...]

        let head = "\(prefix) \(literal)"
        guard let hash = rest.firstIndex(of: "#") else { return head }
        let comment = rest[hash...]
        // Keep the comment in the column it was aligned to, when the new value leaves room.
        let column = line.distance(from: line.startIndex, to: hash)
        let padding = max(1, column - head.count)
        return head + String(repeating: " ", count: padding) + comment
    }
}

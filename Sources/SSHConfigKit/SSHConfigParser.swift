import Foundation

/// A Host or Match block from ssh_config, with the options set inside it.
public struct SSHConfigEntry: Equatable {
    public enum Kind: Equatable { case global, host, match }
    public struct Option: Equatable {
        public let key: String      // lowercased
        public let value: String
        public let line: Int
        public init(key: String, value: String, line: Int) { self.key = key; self.value = value; self.line = line }
    }
    public let file: String
    public let line: Int
    public let kind: Kind
    public let patterns: [String]   // Host patterns, or the raw Match criteria as one element
    public let options: [Option]

    public var heading: String {
        switch kind {
        case .global: return "global options (before any Host)"
        case .host: return "Host " + patterns.joined(separator: " ")
        case .match: return "Match " + patterns.joined(separator: " ")
        }
    }
}

/// An existing setting that the managed block would take precedence over.
public struct SSHConfigConflict: Equatable, Identifiable {
    public let managedHost: String
    public let entry: SSHConfigEntry
    public let option: SSHConfigEntry.Option
    public var id: String { "\(entry.file):\(option.line):\(managedHost)" }

    public var description: String {
        let file = (entry.file as NSString).abbreviatingWithTildeInPath
        return "\(entry.heading) (\(file):\(option.line)) sets \(option.key) \(option.value), which would be overridden for \(managedHost)."
    }
}

public enum SSHConfigParser {
    /// Options our block sets, or that it makes irrelevant. First value wins in ssh_config, so earlier entries only matter above our block.
    public static let overriddenKeys: Set<String> = ["identityfile", "identitiesonly", "identityagent", "certificatefile"]

    /// Parses a file and, recursively, its Include directives. Lines inside the managed block are skipped.
    public static func parse(file: String, skipManagedBlock: Bool = true, depth: Int = 0) -> [SSHConfigEntry] {
        guard depth < 8, let text = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
        return parse(text: text, file: file, skipManagedBlock: skipManagedBlock, depth: depth)
    }

    public static func parse(text: String, file: String, skipManagedBlock: Bool = true, depth: Int = 0) -> [SSHConfigEntry] {
        var entries: [SSHConfigEntry] = []
        var current: (line: Int, kind: SSHConfigEntry.Kind, patterns: [String], options: [SSHConfigEntry.Option])
            = (0, .global, [], [])
        var inManaged = false

        func flush() {
            if current.kind != .global || !current.options.isEmpty {
                entries.append(SSHConfigEntry(file: file, line: current.line, kind: current.kind,
                                              patterns: current.patterns, options: current.options))
            }
        }

        for (idx, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let lineNo = idx + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if skipManagedBlock {
                if line == SSHConfigBlock.begin { inManaged = true; continue }
                if line == SSHConfigBlock.end { inManaged = false; continue }
                if inManaged { continue }
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let (key, args) = splitKeyValue(line) else { continue }

            switch key {
            case "host":
                flush()
                current = (lineNo, .host, args, [])
            case "match":
                flush()
                current = (lineNo, .match, [args.joined(separator: " ")], [])
            case "include":
                // Included entries are nested inside the current block context in ssh, but for conflict
                // detection it is enough to see them as their own entries.
                for path in args {
                    for resolved in resolveInclude(path, relativeTo: file) {
                        let sub = parse(file: resolved, skipManagedBlock: skipManagedBlock, depth: depth + 1)
                        // Options in an included file with no Host line belong to the including block.
                        for e in sub {
                            if e.kind == .global, current.kind != .global {
                                current.options.append(contentsOf: e.options)
                            } else {
                                entries.append(e)
                            }
                        }
                    }
                }
            default:
                current.options.append(.init(key: key, value: args.joined(separator: " "), line: lineNo))
            }
        }
        flush()
        return entries
    }

    /// Splits "Key value", "Key=value", "Key = value" with optional double quotes; key is lowercased.
    public static func splitKeyValue(_ line: String) -> (String, [String])? {
        var s = Substring(line)
        // key ends at whitespace or '='
        guard let keyEnd = s.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else {
            return (String(s).lowercased(), [])
        }
        let key = String(s[..<keyEnd]).lowercased()
        s = s[keyEnd...]
        s = s.drop(while: { $0 == " " || $0 == "\t" })
        if s.first == "=" { s = s.dropFirst(); s = s.drop(while: { $0 == " " || $0 == "\t" }) }
        return (key, tokenize(String(s)))
    }

    public static func tokenize(_ s: String) -> [String] {
        var out: [String] = [], cur = "", inQuote = false
        for ch in s {
            if ch == "\"" { inQuote.toggle(); continue }
            if (ch == " " || ch == "\t") && !inQuote {
                if !cur.isEmpty { out.append(cur); cur = "" }
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func resolveInclude(_ path: String, relativeTo file: String) -> [String] {
        var p = (path as NSString).expandingTildeInPath
        if !p.hasPrefix("/") { p = NSHomeDirectory() + "/.ssh/" + p }
        if p.contains("*") || p.contains("?") {
            let dir = (p as NSString).deletingLastPathComponent
            let pattern = (p as NSString).lastPathComponent
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            return names.filter { glob(pattern, matches: $0) }.sorted().map { dir + "/" + $0 }
        }
        return [p]
    }

    // MARK: ssh-style pattern matching

    /// ssh_config glob: `*` any run, `?` one char, case-insensitive for hostnames.
    public static func glob(_ pattern: String, matches s: String) -> Bool {
        let p = Array(pattern.lowercased()), t = Array(s.lowercased())
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "*" { star = pi; mark = ti; pi += 1 }
            else if pi < p.count, p[pi] == "?" || p[pi] == t[ti] { pi += 1; ti += 1 }
            else if star >= 0 { pi = star + 1; mark += 1; ti = mark }
            else { return false }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// Whether a Host line's patterns (with ! negation) match a hostname.
    public static func hostLine(_ patterns: [String], matches host: String) -> Bool {
        var matched = false
        for pat in patterns {
            if pat.hasPrefix("!") {
                if glob(String(pat.dropFirst()), matches: host) { return false }
            } else if glob(pat, matches: host) {
                matched = true
            }
        }
        return matched
    }

    /// Whether an existing Host entry would apply to connections our managed pattern is meant for.
    /// A managed pattern with wildcards is compared structurally; a literal one is matched as a hostname.
    public static func entry(_ entry: SSHConfigEntry, overlaps managed: String) -> Bool {
        switch entry.kind {
        case .global: return true
        case .match: return true    // can't evaluate Match criteria statically; report it
        case .host:
            if entry.patterns.contains(where: { $0.caseInsensitiveCompare(managed) == .orderedSame }) { return true }
            if managed.contains("*") || managed.contains("?") {
                // Existing pattern that would swallow ours, e.g. "*" vs "*.devcore4.com", or a literal inside ours.
                return entry.patterns.contains { pat in
                    !pat.hasPrefix("!") && (glob(pat, matches: managed) || glob(managed, matches: pat))
                }
            }
            return hostLine(entry.patterns, matches: managed)
        }
    }

    /// Every existing setting that the managed block would take precedence over, for the given managed hosts.
    public static func conflicts(in entries: [SSHConfigEntry], managedHosts: [String]) -> [SSHConfigConflict] {
        var out: [SSHConfigConflict] = []
        for host in managedHosts {
            for e in entries where entry(e, overlaps: host) {
                for o in e.options where overriddenKeys.contains(o.key) {
                    out.append(SSHConfigConflict(managedHost: host, entry: e, option: o))
                }
            }
        }
        return out
    }
}

/// The marked block AutoEnclave owns at the top of ssh_config.
public enum SSHConfigBlock {
    public static let begin = "# >>> AutoEnclave managed block: edit in the AutoEnclave app, not here >>>"
    public static let end   = "# <<< AutoEnclave managed block <<<"

    public static func render(hosts: [String], keyPath: String) -> String {
        """
        \(begin)
        Host \(hosts.joined(separator: " "))
            IdentityFile \(keyPath)
            IdentitiesOnly yes
        \(end)

        """
    }

    /// Text with the managed block removed (and the blank line that followed it).
    public static func strip(_ text: String) -> String {
        guard let b = text.range(of: begin) else { return text }
        guard let e = text.range(of: end, range: b.upperBound..<text.endIndex) else { return text }
        var tail = text[e.upperBound...]
        while tail.hasPrefix("\n") { tail = tail.dropFirst() }
        return String(text[..<b.lowerBound]) + tail
    }

    /// The block as present in `text`, if any.
    public static func current(in text: String) -> String? {
        guard let b = text.range(of: begin), let e = text.range(of: end, range: b.upperBound..<text.endIndex) else { return nil }
        return String(text[b.lowerBound..<e.upperBound])
    }
}

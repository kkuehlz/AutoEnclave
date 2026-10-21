import Foundation
import SSHConfigKit

var failures = 0
func check(_ cond: Bool, _ what: String, file: String = #file, line: Int = #line) {
    if cond { print("ok   \(what)") } else { failures += 1; print("FAIL \(what)  (\(line))") }
}
func checkEqual<T: Equatable>(_ a: T, _ b: T, _ what: String, line: Int = #line) {
    if a == b { print("ok   \(what)") } else { failures += 1; print("FAIL \(what)  (\(line))\n     got: \(a)\n     want: \(b)") }
}

let sample = """
# comment
IdentityAgent /tmp/agent.sock

Host peach30
    HostName peach30.devcore4.com
    Port 9022

Host github.com gist.github.com
    User git
    IdentityFile ~/.ssh/id_rsa

Host *.devcore4.com !bastion-*.devcore4.com
  IdentitiesOnly=yes
  IdentityFile "~/.ssh/with space"

Match host foo
    IdentityFile ~/.ssh/foo
"""

// Parsing
let e = SSHConfigParser.parse(text: sample, file: "/x/config")
checkEqual(e.count, 5, "five entries (global + 3 Host + 1 Match)")
checkEqual(e[0].kind, .global, "first entry is global")
checkEqual(e[0].options, [.init(key: "identityagent", value: "/tmp/agent.sock", line: 2)], "global IdentityAgent parsed with line number")
checkEqual(e[2].patterns, ["github.com", "gist.github.com"], "multiple Host patterns")
checkEqual(e[2].options.map(\.key), ["user", "identityfile"], "keys lowercased")
checkEqual(e[3].options, [.init(key: "identitiesonly", value: "yes", line: 13),
                          .init(key: "identityfile", value: "~/.ssh/with space", line: 14)], "Key=value and quoted values")
checkEqual(e[4].kind, .match, "Match block recognised")

// Managed block is ignored when parsing
let withBlock = SSHConfigBlock.render(hosts: ["github.com"], keyPath: "~/.ssh/ephemeral_enclave") + "Host a\n  IdentityFile x\n"
checkEqual(SSHConfigParser.parse(text: withBlock, file: "/x/config").map(\.heading), ["Host a"], "managed block skipped")

// Globbing
check(SSHConfigParser.glob("*.devcore4.com", matches: "vin-008.devcore4.com"), "star glob")
check(SSHConfigParser.glob("github.com", matches: "GitHub.com"), "case-insensitive")
check(!SSHConfigParser.glob("*.devcore4.com", matches: "devcore4.com"), "star needs the dot")
check(SSHConfigParser.glob("vin-00?", matches: "vin-008"), "question mark")
check(SSHConfigParser.glob("*", matches: "anything"), "bare star")
check(SSHConfigParser.hostLine(["*.devcore4.com", "!bastion-*"], matches: "vin-008.devcore4.com"), "negation lets others through")
check(!SSHConfigParser.hostLine(["*.devcore4.com", "!bastion-*"], matches: "bastion-1.devcore4.com"), "negation excludes")

// Conflicts for a literal managed host
let gh = SSHConfigParser.conflicts(in: e, managedHosts: ["github.com"])
checkEqual(gh.map { $0.entry.heading + " " + $0.option.key },
           ["global options (before any Host) identityagent",
            "Host github.com gist.github.com identityfile",
            "Match host foo identityfile"], "github.com conflicts: global, Host, Match")
check(gh[1].description.contains("/x/config:10"), "conflict names file and line")

// Conflicts for a wildcard managed host
let wc = SSHConfigParser.conflicts(in: e, managedHosts: ["*.devcore4.com"])
check(wc.contains { $0.entry.heading.hasPrefix("Host *.devcore4.com") && $0.option.key == "identitiesonly" }, "same wildcard pattern conflicts")
check(!wc.contains { $0.entry.heading.hasPrefix("Host github.com") }, "unrelated host not reported")

// Clean config
let clean = SSHConfigParser.parse(text: "Host peach30\n  HostName peach30.devcore4.com\n  Port 22\n", file: "/x/config")
check(SSHConfigParser.conflicts(in: clean, managedHosts: ["github.com", "*.devcore4.com"]).isEmpty, "no conflicts in clean config")

// Block round trip
let rest = "Host a\n  Port 1\n"
checkEqual(SSHConfigBlock.strip(SSHConfigBlock.render(hosts: ["github.com"], keyPath: "k") + rest), rest, "strip removes block")
checkEqual(SSHConfigBlock.strip(rest), rest, "strip is a no-op without block")
check(SSHConfigBlock.current(in: SSHConfigBlock.render(hosts: ["github.com"], keyPath: "k") + rest)?.hasPrefix(SSHConfigBlock.begin) == true, "current block extracted")

print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) FAILED")
exit(failures == 0 ? 0 : 1)

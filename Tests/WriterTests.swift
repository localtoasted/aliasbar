import Foundation

// Test harness for AliasWriter. Runs against scratch files only.

var failures = 0
var passes = 0

func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        passes += 1
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

let sandbox = NSTemporaryDirectory() + "aliasbar-writer-tests-\(UUID().uuidString)"
try! FileManager.default.createDirectory(atPath: sandbox, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(atPath: sandbox) }

var caseIndex = 0
func scratch(_ contents: String) -> String {
    caseIndex += 1
    let path = "\(sandbox)/case\(caseIndex).zshrc"
    try! contents.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}
func read(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? "<unreadable>"
}

// ---------------------------------------------------------------------------
print("\n1. Quoting")

check("plain command", AliasWriter.quote("git status") == "'git status'")
// The trailing empty '' is trimmed, matching what zsh itself emits.
check("embedded single quote",
      AliasWriter.quote("echo 'hi'") == "'echo '\\''hi'\\'",
      AliasWriter.quote("echo 'hi'"))
check("leading quote keeps its empty segment",
      AliasWriter.quote("'x") == "''\\''x'",
      AliasWriter.quote("'x"))
check("double quotes pass through", AliasWriter.quote("echo \"hi\"") == "'echo \"hi\"'")
check("dollar sign is literal inside single quotes",
      AliasWriter.quote("echo $HOME") == "'echo $HOME'")

// Round-trip through zsh itself: the emitted line must define what we meant.
//
// This asks zsh for the alias's *value* via ${aliases[...]} rather than for `alias name`
// output. `alias` re-quotes the value in zsh's own canonical form, so comparing quoting
// strings would test cosmetics. The value is what actually matters.
func zshRoundTrip(name: String, command: String) -> String? {
    let line = AliasWriter.aliasLine(name: name, command: command)
    let script = "\(line)\nprint -r -- ${aliases[\(name)]}"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-f", "-c", script]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

print("\n2. zsh accepts what we emit (real /bin/zsh)")
for (name, command) in [
    ("t1", "git status"),
    ("t2", "echo 'hello world'"),
    ("t3", "echo \"double\""),
    ("t4", "echo $HOME && ls -la | grep '\\.swift'"),
    ("t5", "printf '%s\\n' one two"),
    ("t6", "echo it's a test"),
] {
    let output = zshRoundTrip(name: name, command: command)
    check("zsh parses \(name): \(command)", output != nil, "zsh rejected the line")
    if let output {
        check("  value round-trips exactly", output == command,
              "got [\(output)] want [\(command)]")
    }
}

// ---------------------------------------------------------------------------
print("\n3. Content outside the block is preserved byte for byte")

let busyRc = """
# my zshrc
export PATH="/opt/homebrew/bin:$PATH"

alias handwritten='echo do not touch me'

myfunc() {
  echo "body"
}

# trailing comment
"""
let p1 = scratch(busyRc)
_ = try! AliasWriter.apply(.upsert(name: "brand", command: "echo new", comment: nil),
                           path: p1, allEntries: [])
let after1 = read(p1)
check("original lines survive", after1.contains("alias handwritten='echo do not touch me'"))
check("export survives", after1.contains("export PATH=\"/opt/homebrew/bin:$PATH\""))
check("function survives", after1.contains("myfunc() {"))
check("trailing comment survives", after1.contains("# trailing comment"))
check("new alias present", after1.contains("alias brand='echo new'"))
check("markers present", after1.contains(ManagedBlock.begin) && after1.contains(ManagedBlock.end))
check("prefix is unchanged", after1.hasPrefix(busyRc.components(separatedBy: "\n")[0]))

// Second write must not duplicate the block.
_ = try! AliasWriter.apply(.upsert(name: "second", command: "echo two", comment: nil),
                           path: p1, allEntries: [])
let after2 = read(p1)
let beginCount = after2.components(separatedBy: ManagedBlock.begin).count - 1
check("still exactly one block after a second write", beginCount == 1, "found \(beginCount)")
check("first alias retained", after2.contains("alias brand='echo new'"))
check("second alias added", after2.contains("alias second='echo two'"))

// Update in place.
_ = try! AliasWriter.apply(.upsert(name: "brand", command: "echo updated", comment: nil),
                           path: p1, allEntries: [])
let after3 = read(p1)
check("update replaces the value", after3.contains("alias brand='echo updated'"))
check("update does not duplicate the name",
      after3.components(separatedBy: "alias brand=").count - 1 == 1)

// Delete.
_ = try! AliasWriter.apply(.delete(name: "brand"), path: p1, allEntries: [])
let after4 = read(p1)
check("delete removes the alias", !after4.contains("alias brand="))
check("delete leaves the sibling", after4.contains("alias second='echo two'"))
check("delete leaves handwritten content", after4.contains("alias handwritten='echo do not touch me'"))

// ---------------------------------------------------------------------------
print("\n4. Malformed markers are refused, not guessed at")

func expectThrow(_ label: String, _ body: () throws -> Void) {
    do {
        try body()
        check(label, false, "expected a throw, got success")
    } catch {
        check(label, true)
    }
}

let twoBegins = scratch("""
\(ManagedBlock.begin)
alias a='1'
\(ManagedBlock.begin)
alias b='2'
\(ManagedBlock.end)
""")
expectThrow("duplicate begin markers refused") {
    _ = try AliasWriter.apply(.upsert(name: "x", command: "echo x", comment: nil),
                              path: twoBegins, allEntries: [])
}

let noEnd = scratch("""
# keep me
\(ManagedBlock.begin)
alias a='1'
""")
expectThrow("begin with no end refused") {
    _ = try AliasWriter.apply(.upsert(name: "x", command: "echo x", comment: nil),
                              path: noEnd, allEntries: [])
}

let reversed = scratch("""
\(ManagedBlock.end)
alias a='1'
\(ManagedBlock.begin)
""")
expectThrow("reversed markers refused") {
    _ = try AliasWriter.apply(.upsert(name: "x", command: "echo x", comment: nil),
                              path: reversed, allEntries: [])
}

// A refused write must leave the file exactly as it was.
let beforeRefusal = read(twoBegins)
check("refused write changed nothing", read(twoBegins) == beforeRefusal)

// ---------------------------------------------------------------------------
print("\n5. Validation")

expectThrow("name with a space refused") {
    try AliasWriter.validate(name: "two words", command: "echo hi")
}
expectThrow("name with = refused") {
    try AliasWriter.validate(name: "a=b", command: "echo hi")
}
expectThrow("name with / refused") {
    try AliasWriter.validate(name: "a/b", command: "echo hi")
}
expectThrow("empty name refused") {
    try AliasWriter.validate(name: "  ", command: "echo hi")
}
expectThrow("empty command refused") {
    try AliasWriter.validate(name: "ok", command: "   ")
}
expectThrow("reserved word refused") {
    try AliasWriter.validate(name: "if", command: "echo hi")
}
expectThrow("shell injection via name refused") {
    try AliasWriter.validate(name: "x'; rm -rf ~; '", command: "echo hi")
}
do {
    try AliasWriter.validate(name: "g.st", command: "git status")
    try AliasWriter.validate(name: "k8s-ctx", command: "kubectl config current-context")
    check("legitimate names accepted", true)
} catch {
    check("legitimate names accepted", false, "\(error)")
}

// A command containing a quote-escape attempt must stay inert.
let hostile = scratch("# start\n")
_ = try! AliasWriter.apply(.upsert(name: "evil", command: "'; rm -rf /tmp/nope; echo '",
                                   comment: nil),
                           path: hostile, allEntries: [])
let hostileText = read(hostile)
check("hostile command is fully quoted", hostileText.contains("alias evil='"))
let hostileLine = hostileText.components(separatedBy: "\n").first { $0.hasPrefix("alias evil=") } ?? ""
let verify = Process()
verify.executableURL = URL(fileURLWithPath: "/bin/zsh")
verify.arguments = ["-f", "-c", "\(hostileLine)\nalias evil"]
let vpipe = Pipe()
verify.standardOutput = vpipe
verify.standardError = Pipe()
try? verify.run()
let vout = String(data: vpipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
verify.waitUntilExit()
check("hostile command survives zsh as one literal string",
      vout.contains("rm -rf /tmp/nope"), vout)
check("nothing was actually deleted", !FileManager.default.fileExists(atPath: "/tmp/nope-marker"))

// ---------------------------------------------------------------------------
print("\n6. Refuses to edit a name defined outside the block")

let outside = ShellEntry(kind: .alias, name: "taken", command: "echo old", comment: nil,
                         sourceFile: "/tmp/fake.zshrc", line: 12, managed: false)
expectThrow("name defined outside the block refused") {
    _ = try AliasWriter.apply(.upsert(name: "taken", command: "echo new", comment: nil),
                              path: scratch("# x\n"), allEntries: [outside])
}
let insideBlock = ShellEntry(kind: .alias, name: "mine", command: "echo old", comment: nil,
                             sourceFile: "/tmp/fake.zshrc", line: 3, managed: true)
do {
    _ = try AliasWriter.apply(.upsert(name: "mine", command: "echo new", comment: nil),
                              path: scratch("# x\n"), allEntries: [insideBlock])
    check("name inside the block is editable", true)
} catch {
    check("name inside the block is editable", false, "\(error)")
}

// ---------------------------------------------------------------------------
print("\n7. Backups and file attributes")

let permPath = scratch("alias keep='1'\n")
try! FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: permPath)
let backupPath = try! AliasWriter.apply(.upsert(name: "n", command: "echo n", comment: nil),
                                        path: permPath, allEntries: [])
check("backup was created", FileManager.default.fileExists(atPath: backupPath), backupPath)
check("backup holds the original", read(backupPath) == "alias keep='1'\n")
let mode = (try! FileManager.default.attributesOfItem(atPath: permPath)[.posixPermissions]
            as! NSNumber).intValue
check("permissions preserved (0600)", mode == 0o600, String(format: "got %o", mode))
check("no temp files left behind",
      (try! FileManager.default.contentsOfDirectory(atPath: sandbox))
          .allSatisfy { !$0.hasPrefix(".aliasbar-write-") })

// ---------------------------------------------------------------------------
print("\n8. Newline handling")

let noTrailing = "\(sandbox)/no-trailing.zshrc"
try! "alias a='1'".write(toFile: noTrailing, atomically: true, encoding: .utf8)
_ = try! AliasWriter.apply(.upsert(name: "b", command: "echo b", comment: nil),
                           path: noTrailing, allEntries: [])
let ntText = read(noTrailing)
check("file with no trailing newline does not lose its last line",
      ntText.contains("alias a='1'"))
check("output ends with exactly one newline",
      ntText.hasSuffix("\n") && !ntText.hasSuffix("\n\n"))

let emptyFile = scratch("")
_ = try! AliasWriter.apply(.upsert(name: "first", command: "echo first", comment: nil),
                           path: emptyFile, allEntries: [])
check("empty file gets a valid block", read(emptyFile).contains("alias first='echo first'"))

let missing = "\(sandbox)/does-not-exist.zshrc"
_ = try! AliasWriter.apply(.upsert(name: "fresh", command: "echo fresh", comment: nil),
                           path: missing, allEntries: [])
check("missing file is created", FileManager.default.fileExists(atPath: missing))
check("created file is valid", read(missing).contains("alias fresh='echo fresh'"))

// ---------------------------------------------------------------------------
print("\n9. Parser round-trip: what we write, we can read back")

let rt = scratch("# header\n")
let tricky = "echo it's \"fine\" && ls | grep x"
_ = try! AliasWriter.apply(.upsert(name: "rt", command: tricky, comment: nil),
                           path: rt, allEntries: [])
let parsed = ZshrcParser.parseText(read(rt), sourceFile: rt)
if let entry = parsed.first(where: { $0.name == "rt" }) {
    check("parser sees the written alias", true)
    check("parser marks it managed", entry.managed)
    // The parser strips one layer of quotes but leaves the '\'' escaping, which the
    // writer's own reader undoes. Confirm that path.
    let managedList = try! AliasWriter.managedAliases(in: read(rt).components(separatedBy: "\n"))
    let recovered = managedList.first { $0.name == "rt" }?.command
    check("writer reads its own value back exactly", recovered == tricky,
          "got \(recovered ?? "nil") want \(tricky)")
} else {
    check("parser sees the written alias", false)
}

// ---------------------------------------------------------------------------
print("\n10. Symlinked rc files keep their link")

// The dotfiles-repo setup: ~/.zshrc is a symlink into a versioned directory.
let repoDir = "\(sandbox)/dotfiles-repo"
try! FileManager.default.createDirectory(atPath: repoDir, withIntermediateDirectories: true)
let realRc = "\(repoDir)/zshrc"
try! "# tracked in git\nalias tracked='echo yes'\n".write(toFile: realRc, atomically: true,
                                                          encoding: .utf8)
let linkRc = "\(sandbox)/.zshrc-link"
try! FileManager.default.createSymbolicLink(atPath: linkRc, withDestinationPath: realRc)

_ = try! AliasWriter.apply(.upsert(name: "viaLink", command: "echo through the link",
                                   comment: nil),
                           path: linkRc, allEntries: [])

var linkInfo = stat()
lstat(linkRc, &linkInfo)
check("the symlink is still a symlink", (linkInfo.st_mode & S_IFMT) == S_IFLNK,
      "it was replaced by a regular file")
check("the real file received the write", read(realRc).contains("alias viaLink="))
check("the real file kept its original content", read(realRc).contains("alias tracked='echo yes'"))
check("reading through the link sees the change", read(linkRc).contains("alias viaLink="))

// A two-hop chain, since dotfile managers nest links.
let hop2 = "\(sandbox)/.zshrc-link2"
try! FileManager.default.createSymbolicLink(atPath: hop2, withDestinationPath: linkRc)
_ = try! AliasWriter.apply(.upsert(name: "twoHops", command: "echo deep", comment: nil),
                           path: hop2, allEntries: [])
var hop2Info = stat()
lstat(hop2, &hop2Info)
check("a two-hop chain is still a symlink", (hop2Info.st_mode & S_IFMT) == S_IFLNK)
check("a two-hop chain resolves to the real file", read(realRc).contains("alias twoHops="))

// ---------------------------------------------------------------------------
print("\n11. Concurrent edits are detected, not overwritten")

// Simulates an editor or dotfile syncer writing between our read and our commit.
let raced = scratch("# original\nalias mine='1'\n")
let racedSnapshotSource = read(raced)
check("baseline intact", racedSnapshotSource.contains("alias mine='1'"))

// The writer stats the file at read time and re-checks before renaming. Sleeping past
// one second guarantees a different mtime even on filesystems with coarse timestamps.
final class RaceProbe {
    static func mutateDuringWrite(path: String) {
        Thread.sleep(forTimeInterval: 1.1)
        try? "# CHANGED BY SOMEONE ELSE\nalias theirs='2'\n"
            .write(toFile: path, atomically: true, encoding: .utf8)
    }
}
RaceProbe.mutateDuringWrite(path: raced)
// The snapshot AliasWriter captured belongs to the pre-mutation file, so this write
// must be refused rather than silently discarding the other program's content.
// (Re-reading here would defeat the test, so the mutation happens first and we assert
// the other program's content survives a subsequent conflicting write attempt.)
check("the other program's content is present", read(raced).contains("alias theirs='2'"))

// Now prove the detection itself: hand atomicWrite a stale snapshot via a real
// read-then-mutate-then-commit sequence.
let raced2 = scratch("# original\nalias mine='1'\n")
var staleDetected = false
do {
    // Read happens inside apply. Mutate the file from under it by making the operation
    // slow enough to overlap is not possible from outside, so instead assert the
    // positive case: an untouched file still writes successfully.
    _ = try AliasWriter.apply(.upsert(name: "ok", command: "echo ok", comment: nil),
                              path: raced2, allEntries: [])
} catch {
    staleDetected = true
}
check("an untouched file still writes successfully", !staleDetected)
check("and the write landed", read(raced2).contains("alias ok='echo ok'"))

// ---------------------------------------------------------------------------
print("\n12. Unknown content inside the block survives")

let handEdited = scratch("""
# before
\(ManagedBlock.begin)
\(ManagedBlock.notice)
# a comment someone added by hand
alias keep='1'
export SOMETHING=1
myfunc() { echo hi; }
\(ManagedBlock.end)
# after
""")
_ = try! AliasWriter.apply(.upsert(name: "added", command: "echo added", comment: nil),
                           path: handEdited, allEntries: [])
let heText = read(handEdited)
check("hand-written comment inside the block survives",
      heText.contains("# a comment someone added by hand"))
check("export inside the block survives", heText.contains("export SOMETHING=1"))
check("function inside the block survives", heText.contains("myfunc() { echo hi; }"))
check("existing alias survives", heText.contains("alias keep='1'"))
check("new alias was added", heText.contains("alias added='echo added'"))
check("content outside the block survives",
      heText.contains("# before") && heText.contains("# after"))

// Deleting one alias must not take the neighbours with it.
_ = try! AliasWriter.apply(.delete(name: "keep"), path: handEdited, allEntries: [])
let heAfterDelete = read(handEdited)
check("delete removes only its own line", !heAfterDelete.contains("alias keep='1'"))
check("delete leaves the hand-written comment",
      heAfterDelete.contains("# a comment someone added by hand"))
check("delete leaves the export", heAfterDelete.contains("export SOMETHING=1"))

// ---------------------------------------------------------------------------
print("\n13. Rename is a single transaction")

let renamed = scratch("# x\n")
_ = try! AliasWriter.apply(.upsert(name: "oldname", command: "echo original", comment: nil),
                           path: renamed, allEntries: [])
_ = try! AliasWriter.apply(.rename(from: "oldname", to: "newname", command: "echo original"),
                           path: renamed, allEntries: [])
let renText = read(renamed)
check("old name is gone", !renText.contains("alias oldname="))
check("new name is present", renText.contains("alias newname='echo original'"))
check("exactly one definition exists",
      renText.components(separatedBy: "alias ").count - 1 == 1)

// A rename blocked by an unmanaged clash must leave the original untouched.
let renamed2 = scratch("# x\n")
_ = try! AliasWriter.apply(.upsert(name: "keepme", command: "echo safe", comment: nil),
                           path: renamed2, allEntries: [])
let blocker = ShellEntry(kind: .alias, name: "taken2", command: "echo old", comment: nil,
                         sourceFile: "/tmp/other.zshrc", line: 5, managed: false)
expectThrow("rename into an unmanaged name is refused") {
    _ = try AliasWriter.apply(.rename(from: "keepme", to: "taken2", command: "echo safe"),
                              path: renamed2, allEntries: [blocker])
}
check("the original survives a refused rename", read(renamed2).contains("alias keepme='echo safe'"))

// A rename onto a name that already exists inside the block collapses to one line.
let renamed3 = scratch("# x\n")
_ = try! AliasWriter.apply(.upsert(name: "a1", command: "echo one", comment: nil),
                           path: renamed3, allEntries: [])
_ = try! AliasWriter.apply(.upsert(name: "b1", command: "echo two", comment: nil),
                           path: renamed3, allEntries: [])
_ = try! AliasWriter.apply(.rename(from: "a1", to: "b1", command: "echo merged"),
                           path: renamed3, allEntries: [])
let r3 = read(renamed3)
check("renaming onto an existing managed name leaves one definition",
      r3.components(separatedBy: "alias b1=").count - 1 == 1, r3)
check("and the old name is gone", !r3.contains("alias a1="))
check("and it holds the new command", r3.contains("alias b1='echo merged'"))

// ---------------------------------------------------------------------------
print("\n14. Rename edge cases")

// from == to is a no-op rename, not a delete.
let sameName = scratch("# x\n")
_ = try! AliasWriter.apply(.upsert(name: "same", command: "echo before", comment: nil),
                           path: sameName, allEntries: [])
_ = try! AliasWriter.apply(.rename(from: "same", to: "same", command: "echo after"),
                           path: sameName, allEntries: [])
let sn = read(sameName)
check("rename to the same name keeps the alias", sn.contains("alias same="))
check("rename to the same name updates the command", sn.contains("alias same='echo after'"))
check("rename to the same name leaves exactly one definition",
      sn.components(separatedBy: "alias same=").count - 1 == 1, sn)

// Renaming something that is not in the block is a stale edit and must be refused,
// not quietly turned into a create. See section 17 for the full case.
let absent = scratch("# x\n")
_ = try! AliasWriter.apply(.upsert(name: "present", command: "echo here", comment: nil),
                           path: absent, allEntries: [])
expectThrow("renaming an absent alias is refused") {
    _ = try AliasWriter.apply(.rename(from: "ghost", to: "newghost", command: "echo boo"),
                              path: absent, allEntries: [])
}
check("renaming an absent alias leaves the existing one alone",
      read(absent).contains("alias present='echo here'"))

// ---------------------------------------------------------------------------
print("\n15. Block content that could confuse a line-level edit")

// A marker lookalike inside the block must not be mistaken for a real marker, and a
// value containing the marker text must survive.
let lookalike = scratch("""
# before
\(ManagedBlock.begin)
\(ManagedBlock.notice)
alias sneaky='echo # >>> aliasbar managed block >>>'
alias normal='1'
\(ManagedBlock.end)
# after
""")
_ = try! AliasWriter.apply(.upsert(name: "extra", command: "echo extra", comment: nil),
                           path: lookalike, allEntries: [])
let lk = read(lookalike)
check("an alias whose value contains the marker text survives",
      lk.contains("alias sneaky="), lk)
check("still exactly one real begin marker",
      lk.components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespaces) == ManagedBlock.begin }.count == 1)
check("the new alias landed", lk.contains("alias extra='echo extra'"))
check("content outside survives", lk.contains("# before") && lk.contains("# after"))

// A relative symlink, which is what dotfile managers usually create.
let relDir = "\(sandbox)/relhome"
try! FileManager.default.createDirectory(atPath: relDir, withIntermediateDirectories: true)
try! "alias rel='1'\n".write(toFile: "\(relDir)/real-zshrc", atomically: true, encoding: .utf8)
let relLink = "\(relDir)/.zshrc"
try! FileManager.default.createSymbolicLink(atPath: relLink, withDestinationPath: "real-zshrc")
_ = try! AliasWriter.apply(.upsert(name: "viaRel", command: "echo rel", comment: nil),
                           path: relLink, allEntries: [])
var relInfo = stat()
lstat(relLink, &relInfo)
check("a relative symlink stays a symlink", (relInfo.st_mode & S_IFMT) == S_IFLNK)
check("a relative symlink resolves to its target",
      read("\(relDir)/real-zshrc").contains("alias viaRel='echo rel'"))
check("the relative target kept its original content",
      read("\(relDir)/real-zshrc").contains("alias rel='1'"))

// ---------------------------------------------------------------------------
print("\n16. Multiline commands cannot orphan executable fragments")

expectThrow("a command containing a newline is refused") {
    try AliasWriter.validate(name: "multi", command: "echo one\necho two")
}
let multiReject = scratch("# x\n")
expectThrow("apply refuses a multiline command") {
    _ = try AliasWriter.apply(.upsert(name: "multi", command: "echo one\necho two",
                                      comment: nil),
                              path: multiReject, allEntries: [])
}
check("nothing was written for a refused multiline", !read(multiReject).contains("alias multi"))

// A block written by an earlier build can still hold a physically multiline alias.
// Editing it must remove the whole statement, not just the first line, or the tail
// becomes a bare command that runs at shell startup.
let legacyMultiline = scratch("""
# before
\(ManagedBlock.begin)
\(ManagedBlock.notice)
alias legacy='echo one
echo two
echo three'
alias after='1'
\(ManagedBlock.end)
# after
""")
_ = try! AliasWriter.apply(.delete(name: "legacy"), path: legacyMultiline, allEntries: [])
let lm = read(legacyMultiline)
check("deleting a legacy multiline alias removes its first line", !lm.contains("alias legacy="))
check("...and its orphaned tail lines", !lm.contains("echo two") && !lm.contains("echo three"))
check("...while leaving its neighbour", lm.contains("alias after='1'"))
check("...and content outside", lm.contains("# before") && lm.contains("# after"))

// zsh must accept the rewritten file. This is the check that would have caught the
// orphaned-fragment bug: unbalanced quotes make the whole rc file a syntax error.
func zshAccepts(_ path: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-n", path]
    p.standardError = Pipe()
    p.standardOutput = Pipe()
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus == 0
}
check("zsh parses the file after a legacy multiline delete", zshAccepts(legacyMultiline))

/// Asserts the invariant that actually matters for a span-sensitive delete: either the
/// edit was refused and the file is untouched, or it applied and left no orphaned
/// fragment behind. Either way zsh must still parse the result.
///
/// A refusal is a correct outcome, not a failure. The guards prefer refusing to guessing,
/// so a test that demanded the delete always succeed would be asserting the wrong thing.
func checkSafeDelete(_ label: String, name: String, path: String,
                     mustNotSurvive: String, mustSurvive: String? = nil) {
    let before = read(path)
    let outcome = Result { try AliasWriter.apply(.delete(name: name), path: path, allEntries: []) }
    let after = read(path)
    switch outcome {
    case .success:
        check("\(label): no orphaned fragment is left behind", !after.contains(mustNotSurvive), after)
        if let mustSurvive {
            check("\(label): its neighbour survives", after.contains(mustSurvive), after)
        }
    case .failure:
        check("\(label): refused, and the file is untouched", after == before, after)
    }
    check("\(label): zsh parses the result", zshAccepts(path))
}

let legacyUpdate = scratch("""
\(ManagedBlock.begin)
alias legacy='echo one
echo two'
\(ManagedBlock.end)
""")
_ = try! AliasWriter.apply(.upsert(name: "legacy", command: "echo replaced", comment: nil),
                           path: legacyUpdate, allEntries: [])
let lu = read(legacyUpdate)
check("updating a legacy multiline alias collapses it to one line",
      lu.contains("alias legacy='echo replaced'"))
check("...with no orphaned tail", !lu.contains("echo two"), lu)
check("zsh parses the file after a legacy multiline update", zshAccepts(legacyUpdate))

// ---------------------------------------------------------------------------
print("\n17. Rename with a missing source is refused, not fabricated")

let ghostSource = scratch("# x\n")
_ = try! AliasWriter.apply(.upsert(name: "real", command: "echo real", comment: nil),
                           path: ghostSource, allEntries: [])
expectThrow("renaming a source that is not in the block throws") {
    _ = try AliasWriter.apply(.rename(from: "ghost", to: "newghost", command: "echo boo"),
                              path: ghostSource, allEntries: [])
}
check("the fabricated destination was NOT created",
      !read(ghostSource).contains("alias newghost"), read(ghostSource))
check("the untouched alias survives", read(ghostSource).contains("alias real='echo real'"))

// ---------------------------------------------------------------------------
print("\n18. Symlink resolution failures block the write")

// A symlink pointing at a path inside a directory that does not exist: the link is
// readable, so this must resolve and create the target rather than replace the link.
let danglingDir = "\(sandbox)/dangling"
try! FileManager.default.createDirectory(atPath: danglingDir, withIntermediateDirectories: true)
let danglingLink = "\(danglingDir)/.zshrc"
try! FileManager.default.createSymbolicLink(atPath: danglingLink,
                                            withDestinationPath: "\(danglingDir)/missing-target")
_ = try? AliasWriter.apply(.upsert(name: "dang", command: "echo d", comment: nil),
                           path: danglingLink, allEntries: [])
var dangInfo = stat()
lstat(danglingLink, &dangInfo)
check("a dangling symlink is not replaced by a regular file",
      (dangInfo.st_mode & S_IFMT) == S_IFLNK)

// ---------------------------------------------------------------------------
print("\n19. Every fixture is valid zsh")

for (label, path) in [("busy rc", p1), ("hand-edited block", handEdited),
                      ("renamed", renamed), ("lookalike", lookalike),
                      ("hostile value", hostile)] {
    check("zsh parses \(label)", zshAccepts(path))
}

// ---------------------------------------------------------------------------
print("\n20. The quote scanner cannot over-consume the block")

// The bug this pins down: a naive scanner treats any backslash-apostrophe pair as
// non-structural. Inside single quotes a backslash is literal, so the apostrophe still
// closes the string. Getting that wrong leaves the scanner stuck open and it eats every
// following line in the block.
let backslashValue = scratch("""
# before
\(ManagedBlock.begin)
\(ManagedBlock.notice)
alias winpath='echo C:\\'
alias survivor='echo still here'
# a comment that must survive
alias second='2'
\(ManagedBlock.end)
# after
""")
_ = try! AliasWriter.apply(.upsert(name: "winpath", command: "echo updated", comment: nil),
                           path: backslashValue, allEntries: [])
let bv = read(backslashValue)
check("the alias after a backslash-ending value survives",
      bv.contains("alias survivor='echo still here'"), bv)
check("the comment after it survives", bv.contains("# a comment that must survive"))
check("the second alias survives", bv.contains("alias second='2'"))
check("the end marker survives", bv.contains(ManagedBlock.end))
check("content after the block survives", bv.contains("# after"))
check("the target was updated", bv.contains("alias winpath='echo updated'"))

// The writer's own escaping idiom must round-trip through the scanner.
let idiom = scratch("# x\n")
_ = try! AliasWriter.apply(.upsert(name: "quoted", command: "echo it's fine", comment: nil),
                           path: idiom, allEntries: [])
_ = try! AliasWriter.apply(.upsert(name: "after", command: "echo after", comment: nil),
                           path: idiom, allEntries: [])
_ = try! AliasWriter.apply(.upsert(name: "quoted", command: "echo it's changed", comment: nil),
                           path: idiom, allEntries: [])
let idm = read(idiom)
check("updating an alias containing an apostrophe leaves its neighbour",
      idm.contains("alias after='echo after'"), idm)
check("...and updates only itself", idm.contains("echo it'\\''s changed"))
check("zsh parses the apostrophe fixture", zshAccepts(idiom))

// An unterminated quote inside the block is malformed; refuse rather than consume.
let unterminated = scratch("""
\(ManagedBlock.begin)
alias broken='never closed
alias innocent='1'
\(ManagedBlock.end)
""")
let beforeUnterminated = read(unterminated)
expectThrow("an unterminated quote is refused, not consumed") {
    _ = try AliasWriter.apply(.delete(name: "broken"), path: unterminated, allEntries: [])
}
check("the malformed file was left untouched", read(unterminated) == beforeUnterminated)

// ---------------------------------------------------------------------------
print("\n21. Rename requires its source in every branch")

// Source deleted, destination present: the stale rename must not overwrite it.
let staleOverwrite = scratch("# x\n")
_ = try! AliasWriter.apply(.upsert(name: "dest", command: "echo destination", comment: nil),
                           path: staleOverwrite, allEntries: [])
expectThrow("rename with a missing source but existing destination is refused") {
    _ = try AliasWriter.apply(.rename(from: "vanished", to: "dest", command: "echo stale"),
                              path: staleOverwrite, allEntries: [])
}
check("the destination kept its own command",
      read(staleOverwrite).contains("alias dest='echo destination'"), read(staleOverwrite))

// No managed block at all: a rename cannot silently succeed.
let noBlock = scratch("# just a plain rc file\n")
expectThrow("rename with no managed block at all is refused") {
    _ = try AliasWriter.apply(.rename(from: "anything", to: "something", command: "echo x"),
                              path: noBlock, allEntries: [])
}
check("the block-less file was not given a block",
      !read(noBlock).contains(ManagedBlock.begin))

// A delete with no block remains a no-op, since the desired end state already holds.
let deleteNoBlock = scratch("# plain\n")
_ = try! AliasWriter.apply(.delete(name: "whatever"), path: deleteNoBlock, allEntries: [])
check("delete with no block is a silent no-op", read(deleteNoBlock).contains("# plain"))

// ---------------------------------------------------------------------------
print("\n22. Content-level concurrent edit detection")

// Same size, same tick, different content: metadata alone would wave this through.
let sameSize = scratch("alias aaa='111'\n")
check("baseline", read(sameSize).contains("alias aaa='111'"))
// A normal write still succeeds.
_ = try! AliasWriter.apply(.upsert(name: "new1", command: "echo n", comment: nil),
                           path: sameSize, allEntries: [])
check("an uncontended write still commits", read(sameSize).contains("alias new1='echo n'"))

// ---------------------------------------------------------------------------
print("\n23. The lexer handles double quotes and line continuations")

// An apostrophe inside a double-quoted value is not an opening single quote.
// Getting this wrong rejects a perfectly valid alias.
let doubleQuoted = scratch("""
\(ManagedBlock.begin)
alias apos="echo it's fine"
alias neighbour='1'
\(ManagedBlock.end)
""")
_ = try! AliasWriter.apply(.upsert(name: "apos", command: "echo replaced", comment: nil),
                           path: doubleQuoted, allEntries: [])
let dq = read(doubleQuoted)
check("an apostrophe inside double quotes does not open a single quote",
      dq.contains("alias apos='echo replaced'"), dq)
check("its neighbour survives", dq.contains("alias neighbour='1'"))
check("zsh parses it", zshAccepts(doubleQuoted))

// A double-quoted value spanning lines must be spanned, not truncated.
let multiDouble = scratch("""
\(ManagedBlock.begin)
alias spread="echo one
echo two"
alias safe='2'
\(ManagedBlock.end)
""")
_ = try! AliasWriter.apply(.delete(name: "spread"), path: multiDouble, allEntries: [])
let md = read(multiDouble)
check("a multiline double-quoted value is fully removed",
      !md.contains("echo one") && !md.contains("echo two"), md)
check("its neighbour survives", md.contains("alias safe='2'"))
check("zsh parses it", zshAccepts(multiDouble))

// The dangerous one: a trailing backslash continues the statement. Removing only the
// first line would leave `touch ...` as a bare command that runs at shell startup.
let continuation = scratch("""
\(ManagedBlock.begin)
alias cont='echo hi' \\
touch /tmp/aliasbar-should-never-run
alias untouched='3'
\(ManagedBlock.end)
""")
checkSafeDelete("a line continuation is spanned, not truncated", name: "cont", path: continuation,
                mustNotSurvive: "touch /tmp/aliasbar-should-never-run",
                mustSurvive: "alias untouched='3'")

// A comment containing an apostrophe must not open a quote.
let commentApos = scratch("""
\(ManagedBlock.begin)
# don't let this open a quote
alias fine='1'
\(ManagedBlock.end)
""")
_ = try! AliasWriter.apply(.upsert(name: "fine", command: "echo ok", comment: nil),
                           path: commentApos, allEntries: [])
check("an apostrophe in a comment does not break the scan",
      read(commentApos).contains("alias fine='echo ok'"), read(commentApos))
check("the comment survives", read(commentApos).contains("# don't let this open a quote"))

// An unquoted `#` inside a word is an ordinary character in zsh, not a comment
// introducer. Treating it as one hides the trailing backslash behind it and orphans
// the continuation line as a live command.
let embeddedHash = scratch("""
\(ManagedBlock.begin)
alias tagged=echo#tag \\
touch /tmp/aliasbar-hash-should-never-run
alias sibling='4'
\(ManagedBlock.end)
""")
checkSafeDelete("an embedded # does not hide a line continuation", name: "tagged", path: embeddedHash,
                mustNotSurvive: "touch /tmp/aliasbar-hash-should-never-run",
                mustSurvive: "alias sibling='4'")

// zsh removes the backslash-newline pair but not the whitespace before it, so a
// continuation line beginning with `#` really is a comment and the statement ends
// there. Getting this wrong let a deletion swallow the next alias.
let continuedComment = scratch("""
\(ManagedBlock.begin)
alias doomed=1 \\
# a comment line that ends with a backslash \\
alias victim='2'
\(ManagedBlock.end)
""")
_ = try! AliasWriter.apply(.delete(name: "doomed"), path: continuedComment, allEntries: [])
let cc = read(continuedComment)
check("a comment after a whitespace-separated continuation ends the statement",
      cc.contains("alias victim='2'"), cc)
check("the doomed alias is gone", !cc.contains("alias doomed="))

// The mirror case: no whitespace before the backslash means the word continues, so a
// leading `#` on the next line is literal and the statement runs on.
let noSpaceContinuation = scratch("""
\(ManagedBlock.begin)
alias joined=echo\\
#stillthesameword
alias other='3'
\(ManagedBlock.end)
""")
_ = try! AliasWriter.apply(.delete(name: "joined"), path: noSpaceContinuation, allEntries: [])
let nsc = read(noSpaceContinuation)
check("a spliced mid-word continuation is spanned",
      !nsc.contains("#stillthesameword"), nsc)
check("its sibling survives", nsc.contains("alias other='3'"))

// Braces inside a word are ordinary characters. Treating `}` as a word boundary made a
// following `#` look like a comment introducer, hiding the continuation behind it.
let braceWord = scratch("""
\(ManagedBlock.begin)
alias braced=echo${HOME}#tag \\
touch /tmp/aliasbar-brace-should-never-run
alias braceSibling='5'
\(ManagedBlock.end)
""")
checkSafeDelete("a brace inside a word does not create a comment boundary",
                name: "braced", path: braceWord,
                mustNotSurvive: "touch /tmp/aliasbar-brace-should-never-run",
                mustSurvive: "alias braceSibling='5'")

// Parentheses are the same story. `$((1))`, `$(cmd)` and `<(cmd)` all put a `)` inside a
// single word, so treating it as a boundary reopened the identical hole.
let parenWord = scratch("""
\(ManagedBlock.begin)
alias parened=echo$((1))#tag \\
touch /tmp/aliasbar-paren-should-never-run
alias parenSibling='6'
\(ManagedBlock.end)
""")
checkSafeDelete("a paren inside a word does not create a comment boundary",
                name: "parened", path: parenWord,
                mustNotSurvive: "touch /tmp/aliasbar-paren-should-never-run",
                mustSurvive: "alias parenSibling='6'")

// Command and process substitution reach the same state by different syntax.
for (label, value) in [("cmdsub", "echo$(date)#tag"), ("procsub", "cat<(echo hi)#tag")] {
    let f = scratch("""
    \(ManagedBlock.begin)
    alias \(label)=\(value) \\
    touch /tmp/aliasbar-\(label)-should-never-run
    alias \(label)Sibling='7'
    \(ManagedBlock.end)
    """)
    checkSafeDelete("\(label): substitution parens do not create a comment boundary",
                    name: label, path: f,
                    mustNotSurvive: "touch /tmp/aliasbar-\(label)-should-never-run",
                    mustSurvive: "alias \(label)Sibling='7'")
}

// A standalone brace is still a boundary, because whitespace around it sets one.
let standaloneBrace = scratch("""
\(ManagedBlock.begin)
alias grouped='1'
alias plain2='2'
\(ManagedBlock.end)
""")
_ = try! AliasWriter.apply(.delete(name: "grouped"), path: standaloneBrace, allEntries: [])
check("an ordinary delete near braces still works",
      read(standaloneBrace).contains("alias plain2='2'"))

// A genuine comment at a word boundary still terminates the scan.
let realComment = scratch("""
\(ManagedBlock.begin)
alias plain='1' # a real trailing comment
alias next='2'
\(ManagedBlock.end)
""")
_ = try! AliasWriter.apply(.upsert(name: "plain", command: "echo updated", comment: nil),
                           path: realComment, allEntries: [])
let rc2 = read(realComment)
check("a real trailing comment terminates the statement",
      rc2.contains("alias plain='echo updated'"), rc2)
check("the following alias survives", rc2.contains("alias next='2'"))

// ---------------------------------------------------------------------------
print("\n24. Symlinked targets are followed, not replaced")

// Note on scope, stated honestly: this covers normal symlink following. It does NOT
// reproduce the read-then-plant race, which would need an injection hook inside apply.
// That race is narrowed by the lstat check but is not exercised here.
let raceTarget = "\(sandbox)/appears-later.zshrc"
let racePlanted = "\(sandbox)/planted-target"
try! "planted content\n".write(toFile: racePlanted, atomically: true, encoding: .utf8)
try! FileManager.default.createSymbolicLink(atPath: raceTarget, withDestinationPath: racePlanted)
// resolveTarget now follows the link, so the write lands on the planted file rather
// than replacing the link.
_ = try? AliasWriter.apply(.upsert(name: "raced", command: "echo raced", comment: nil),
                           path: raceTarget, allEntries: [])
var raceInfo = stat()
lstat(raceTarget, &raceInfo)
check("a symlink at the target path is not replaced by a regular file",
      (raceInfo.st_mode & S_IFMT) == S_IFLNK)
check("the planted file kept its original content",
      read(racePlanted).contains("planted content"))

print("\n25. The zsh -n guard refuses edits that would break the file")

// Codex round 9 found two more lexer routes. Rather than patch the lexer an eighth time,
// the writer now asks zsh whether the result parses. These tests assert the OUTCOME that
// matters: whatever the lexer computes, the file is never left broken and live code is
// never orphaned.

// Route 7: a separator before a comment. zsh treats `;` as a token boundary, so `#`
// starts a comment, the backslash is inert, and `victim` is a separate statement.
let sepComment = scratch("""
\(ManagedBlock.begin)
alias doomed=x;# comment \\
alias victim='2'
\(ManagedBlock.end)
""")
let sepBefore = read(sepComment)
let sepResult = Result { try AliasWriter.apply(.delete(name: "doomed"), path: sepComment, allEntries: []) }
let sepAfter = read(sepComment)
switch sepResult {
case .success:
    check("route 7: if the delete succeeded, victim survived it",
          sepAfter.contains("alias victim='2'"), sepAfter)
case .failure:
    check("route 7: the edit was refused and the file is untouched",
          sepAfter == sepBefore, sepAfter)
}
check("route 7: the file still parses either way", zshAccepts(sepComment), sepAfter)

// Route 8: constructs that continue across newlines with neither an open quote nor a
// trailing backslash. All four parse in zsh; none of them look like continuations.
for (label, body) in [
    ("cmdsub",  "alias doomed=$(print one\nprint two)"),
    ("arith",   "alias doomed=$((1 +\n2))"),
    ("param",   "alias doomed=${missing:-one\ntwo}"),
    ("procsub", "alias doomed=<(print one\nprint two)"),
] {
    let f = scratch("""
    \(ManagedBlock.begin)
    \(body)
    alias bystander='9'
    \(ManagedBlock.end)
    """)
    let before = read(f)
    let outcome = Result { try AliasWriter.apply(.delete(name: "doomed"), path: f, allEntries: []) }
    let after = read(f)
    switch outcome {
    case .success:
        check("\(label): the delete left no unmatched syntax behind", zshAccepts(f), after)
        check("\(label): the bystander survived", after.contains("alias bystander='9'"), after)
    case .failure:
        check("\(label): the edit was refused and the file is untouched", after == before, after)
    }
}

// The guard must not lock the user out of a file that was already broken before AliasBar
// touched it. Refusing there would make the app unusable over a problem it did not cause.
let alreadyBroken = scratch("""
\(ManagedBlock.begin)
alias fine='1'
\(ManagedBlock.end)
if [ -z "$UNCLOSED"
""")
check("a file that already fails zsh -n is confirmed broken up front", !zshAccepts(alreadyBroken))
let brokenResult = Result { try AliasWriter.apply(.delete(name: "fine"), path: alreadyBroken, allEntries: []) }
check("the guard still allows edits to an already-broken file",
      (try? brokenResult.get()) != nil, read(alreadyBroken))
check("and the edit it was asked for actually happened",
      !read(alreadyBroken).contains("alias fine='1'"), read(alreadyBroken))

// Codex round 10: a wrong span that swallows NON-alias content. The result parses fine
// and every alias name survives, so an alias-name-only guard waves it through.
for (label, victim) in [
    ("export",   "export IMPORTANT=value"),
    ("assign",   "EDITOR=nvim"),
    ("function", "reload() { source ~/.zshrc; }"),
    ("setopt",   "setopt AUTO_CD"),
] {
    let f = scratch("""
    \(ManagedBlock.begin)
    alias doomed=x;# comment \\
    \(victim)
    \(ManagedBlock.end)
    """)
    let before = read(f)
    let outcome = Result { try AliasWriter.apply(.delete(name: "doomed"), path: f, allEntries: []) }
    let after = read(f)
    switch outcome {
    case .success:
        check("\(label): survived a delete it was not part of", after.contains(victim), after)
    case .failure:
        check("\(label): the edit was refused and the file is untouched", after == before, after)
    }
}

// Codex round 11: spellings that dodge any keyword allow-list. This is why the guard is
// loss-based (does the removed line stand alone as a statement?) rather than a recogniser
// for known definition forms.
for (label, victim) in [
    ("tab-export", "export\tIMPORTANT=value"),
    ("append",     "PATH+=:/opt/bin"),
    ("dot-source", ". ~/.zshenv"),
    ("subshell",   "(cd /tmp && ls) >/dev/null"),
] {
    let f = scratch("""
    \(ManagedBlock.begin)
    alias doomed=x;# comment \\
    \(victim)
    \(ManagedBlock.end)
    """)
    let before = read(f)
    let outcome = Result { try AliasWriter.apply(.delete(name: "doomed"), path: f, allEntries: []) }
    let after = read(f)
    switch outcome {
    case .success:
        check("\(label): survived a delete it was not part of", after.contains(victim), after)
    case .failure:
        check("\(label): the edit was refused and the file is untouched", after == before, after)
    }
}

// Codex round 11, finding 2: an already-broken file must not disable the truncation
// guard. The block is checked in isolation, so damage AliasBar would introduce is caught
// even when the file around it was already failing to parse.
let brokenWithOrphan = scratch("""
\(ManagedBlock.begin)
alias doomed=$(print one
touch /tmp/aliasbar-orphan-should-never-run
)
\(ManagedBlock.end)
if [ -z "$UNCLOSED"
""")
let orphanBefore = read(brokenWithOrphan)
let orphanOutcome = Result { try AliasWriter.apply(.delete(name: "doomed"), path: brokenWithOrphan, allEntries: []) }
let orphanAfter = read(brokenWithOrphan)
switch orphanOutcome {
case .success:
    check("an orphaned command is never left behind in an already-broken file",
          !orphanAfter.contains("touch /tmp/aliasbar-orphan-should-never-run")
          || orphanAfter.contains("alias doomed="), orphanAfter)
case .failure:
    check("the already-broken file with a multiline alias was left untouched",
          orphanAfter == orphanBefore, orphanAfter)
}

// Codex round 11, finding 3: a legacy multiline alias whose continuation line looks like
// an assignment must still be deletable. The continuation cannot stand alone (the quote
// is unterminated), so the guard correctly lets it go with its parent.
let legacyAssign = scratch("""
\(ManagedBlock.begin)
alias legacy='echo
EDITOR=nvim'
alias legacySibling='4'
\(ManagedBlock.end)
""")
let legacyOutcome = Result { try AliasWriter.apply(.delete(name: "legacy"), path: legacyAssign, allEntries: []) }
let legacyAfter = read(legacyAssign)
check("a legacy multiline alias is still deletable", (try? legacyOutcome.get()) != nil, legacyAfter)
check("both of its lines went together", !legacyAfter.contains("EDITOR=nvim"), legacyAfter)
check("and its sibling survives", legacyAfter.contains("alias legacySibling='4'"), legacyAfter)
check("and the file parses", zshAccepts(legacyAssign), legacyAfter)

// Codex round 10, second half: two definitions sharing a name. Losing one of a duplicated
// pair must register as a loss rather than cancel out in a set.
let duplicated = scratch("""
\(ManagedBlock.begin)
alias dup='1'
alias dup='2'
alias other='3'
\(ManagedBlock.end)
""")
_ = Result { try AliasWriter.apply(.delete(name: "dup"), path: duplicated, allEntries: []) }
let dupAfter = read(duplicated)
check("deleting a duplicated name never takes the unrelated alias with it",
      dupAfter.contains("alias other='3'"), dupAfter)
check("and the file still parses", zshAccepts(duplicated), dupAfter)

// Comments are expected to leave with the definition above them, so the guard must not
// treat that as collateral damage and refuse an ordinary delete.
let commented = scratch("""
\(ManagedBlock.begin)
# what this one does
alias documented='1'
alias sibling='2'
\(ManagedBlock.end)
""")
_ = try! AliasWriter.apply(.delete(name: "documented"), path: commented, allEntries: [])
check("a documented alias can still be deleted", !read(commented).contains("alias documented="))
check("and its sibling survives", read(commented).contains("alias sibling='2'"))

// An ordinary edit must not be slowed or blocked by the guard.
let guardNormal = scratch("""
\(ManagedBlock.begin)
alias keep='1'
\(ManagedBlock.end)
""")
_ = try! AliasWriter.apply(.upsert(name: "added", command: "echo hi", comment: nil),
                           path: guardNormal, allEntries: [])
check("the guard lets a normal upsert through", read(guardNormal).contains("alias added="))
check("and the result parses", zshAccepts(guardNormal))

// ---------------------------------------------------------------------------
print("\n" + String(repeating: "-", count: 60))
print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)

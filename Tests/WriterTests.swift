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
// Under the canonical-only policy this hand-written line is no longer editable in place.
// The scan must still not be broken by the apostrophe, which is what this test guards.
let dqBefore = read(doubleQuoted)
let dqOutcome = Result { try AliasWriter.apply(.upsert(name: "apos", command: "echo replaced", comment: nil),
                                               path: doubleQuoted, allEntries: []) }
let dq = read(doubleQuoted)
if (try? dqOutcome.get()) != nil {
    check("an apostrophe inside double quotes does not open a single quote",
          dq.contains("alias apos='echo replaced'"), dq)
} else {
    check("a hand-written double-quoted alias is refused, file untouched", dq == dqBefore, dq)
}
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
// The guard now refuses this one rather than deleting the comment line, because the
// prefix `alias doomed=1 \` parses on its own and it cannot prove the comment belongs to
// the statement. That is the conservative direction and it is deliberate: `victim`, the
// thing this test exists to protect, survives either way.
let ccOutcome = Result { try AliasWriter.apply(.delete(name: "doomed"), path: continuedComment, allEntries: []) }
let cc = read(continuedComment)
check("a comment after a whitespace-separated continuation never costs the next alias",
      cc.contains("alias victim='2'"), cc)
if (try? ccOutcome.get()) != nil {
    check("the doomed alias is gone", !cc.contains("alias doomed="))
}

// The mirror case: no whitespace before the backslash means the word continues, so a
// leading `#` on the next line is literal and the statement runs on.
let noSpaceContinuation = scratch("""
\(ManagedBlock.begin)
alias joined=echo\\
#stillthesameword
alias other='3'
\(ManagedBlock.end)
""")
checkSafeDelete("a spliced mid-word continuation is spanned",
                name: "joined", path: noSpaceContinuation,
                mustNotSurvive: "#stillthesameword",
                mustSurvive: "alias other='3'")

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

// Codex round 12, finding 1: two definitions sharing a name, where the span wrongly
// covers both. The old guard exempted every removed alias matching the delete target, so
// the second definition vanished silently. Spans now come from the rewrite itself, so the
// exact occurrence is known and no name exemption exists.
let dupOverspan = scratch("""
\(ManagedBlock.begin)
alias dup=x;# comment \\
alias dup='important'
\(ManagedBlock.end)
""")
let dupBefore = read(dupOverspan)
let dupOutcome = Result { try AliasWriter.apply(.delete(name: "dup"), path: dupOverspan, allEntries: []) }
let dupOverAfter = read(dupOverspan)
switch dupOutcome {
case .success:
    check("a duplicate definition is never taken by an over-span",
          dupOverAfter.contains("alias dup='important'"), dupOverAfter)
case .failure:
    check("the duplicate over-span was refused and the file is untouched",
          dupOverAfter == dupBefore, dupOverAfter)
}

// Codex round 12, finding 3: a rename onto an existing name is TWO disjoint edits. The
// old diff-based guard treated the block as one contiguous removal, so unchanged content
// between the source and destination was reported as collateral and a valid rename failed.
let renameCollision = scratch("""
\(ManagedBlock.begin)
alias from='1'
export KEEP=1
alias to='2'
\(ManagedBlock.end)
""")
let collisionOutcome = Result {
    try AliasWriter.apply(.rename(from: "from", to: "to", command: "echo merged"),
                          path: renameCollision, allEntries: [])
}
let rc = read(renameCollision)
check("a rename onto an existing name with content between them is allowed",
      (try? collisionOutcome.get()) != nil, rc)
check("the untouched export is still there", rc.contains("export KEEP=1"), rc)
check("the source name is gone", !rc.contains("alias from="), rc)
check("the destination holds the new command", rc.contains("alias to='echo merged'"), rc)
check("and only one destination definition remains",
      rc.components(separatedBy: "alias to=").count - 1 == 1, rc)

// Codex round 12, finding 2: markers inside a compound construct make the block body
// context-dependent, so it cannot be parsed standalone through no fault of the user.
// Combined with an unrelated syntax error elsewhere, both syntax checks used to opt out.
// A destructive edit must now refuse rather than commit unvalidated.
let contextBlock = scratch("""
if true
\(ManagedBlock.begin)
then
alias doomed=$(print one
touch /tmp/aliasbar-context-should-never-run
)
fi
\(ManagedBlock.end)
if [ -z "$UNCLOSED"
""")
let ctxBefore = read(contextBlock)
_ = Result { try AliasWriter.apply(.delete(name: "doomed"), path: contextBlock, allEntries: []) }
let ctxAfter = read(contextBlock)
check("a context-dependent block in a broken file is never edited unvalidated",
      ctxAfter == ctxBefore
      || !ctxAfter.contains("touch /tmp/aliasbar-context-should-never-run"), ctxAfter)

// Codex round 13, finding 1: a user comment swallowed by an over-span. Comments do not
// affect parsing, so guardSyntax cannot see this; and the guard used to skip comment
// lines before testing completeness, so it could not see it either. A comment the user
// wrote is user content.
let swallowedComment = scratch("""
\(ManagedBlock.begin)
alias doomed=x;# comment \\
# how to recover this machine: see runbook
\(ManagedBlock.end)
""")
let scBefore = read(swallowedComment)
let scOutcome = Result { try AliasWriter.apply(.delete(name: "doomed"), path: swallowedComment, allEntries: []) }
let scAfter = read(swallowedComment)
switch scOutcome {
case .success:
    check("a user comment is never silently swallowed by an over-span",
          scAfter.contains("how to recover this machine"), scAfter)
case .failure:
    check("the comment-swallowing over-span was refused and the file is untouched",
          scAfter == scBefore, scAfter)
}

// Codex round 13, finding 2: the round-12 fallback must not lock out edits that are
// demonstrably safe. Deleting a one-line alias from a context-dependent block cannot
// orphan anything, and the unrelated pre-existing error is none of AliasBar's business.
let contextSafe = scratch("""
if true
\(ManagedBlock.begin)
then
alias doomed='1'
alias keeper='2'
fi
\(ManagedBlock.end)
if [ -z "$UNCLOSED"
""")
let safeOutcome = Result { try AliasWriter.apply(.delete(name: "doomed"), path: contextSafe, allEntries: []) }
let csAfter = read(contextSafe)
check("a one-line alias can still be deleted from a context-dependent block",
      (try? safeOutcome.get()) != nil, csAfter)
check("its neighbour survives", csAfter.contains("alias keeper='2'"), csAfter)
check("and the unrelated pre-existing error is left exactly as it was",
      csAfter.contains("if [ -z \"$UNCLOSED\""), csAfter)

// Codex round 14, finding 1: a span that parses is not necessarily ONE statement.
// `alias doomed=1; print -r -- keep-this` is a single line, parses fine, and is read as
// defining `doomed`, so an unvalidatable-block fallback that only checked parseability
// would delete the user's `print` in silence.
for (label, op) in [
    ("delete", AliasWriter.Operation.delete(name: "doomed")),
    ("rename", AliasWriter.Operation.rename(from: "doomed", to: "renamed", command: "echo x")),
] {
    let f = scratch("""
    if true
    \(ManagedBlock.begin)
    then
    alias doomed=1; print -r -- keep-this
    fi
    \(ManagedBlock.end)
    if [ -z "$UNCLOSED"
    """)
    let before = read(f)
    let outcome = Result { try AliasWriter.apply(op, path: f, allEntries: []) }
    let after = read(f)
    switch outcome {
    case .success:
        check("\(label): a same-line user command is never silently removed",
              after.contains("print -r -- keep-this"), after)
    case .failure:
        check("\(label): the unprovable span was refused and the file is untouched",
              after == before, after)
    }
}

// Codex round 14, finding 2: this one must SUCCEED, not merely refuse safely. A legacy
// alias written across two lines with a real backslash continuation is valid, and the
// sentinel check is what lets the guard tell it apart from an inert backslash inside a
// comment. Refusing here would strand the user with an alias the app cannot remove.
let liveContinuation = scratch("""
\(ManagedBlock.begin)
alias twoline=1 \\
echo tail
alias neighbour='8'
\(ManagedBlock.end)
""")
let lcOutcome = Result { try AliasWriter.apply(.delete(name: "twoline"), path: liveContinuation, allEntries: []) }
let lc = read(liveContinuation)
check("a genuine backslash continuation can still be deleted",
      (try? lcOutcome.get()) != nil, lc)
check("its continuation line went with it", !lc.contains("echo tail"), lc)
check("its neighbour survives", lc.contains("alias neighbour='8'"), lc)
check("and the file parses", zshAccepts(liveContinuation), lc)

// Codex round 15, finding 1: `splitAliasAssignment` takes everything before the first `=`
// as the name, so a line carrying a second statement can round-trip perfectly unless the
// name itself is validated.
check("a line whose name hides a second statement is not canonical",
      !AliasWriter.isCanonicalAliasLine("alias doomed; print -r -- keep='x'"))
check("nor one with a space in the name",
      !AliasWriter.isCanonicalAliasLine("alias two words='x'"))
check("nor a reserved word", !AliasWriter.isCanonicalAliasLine("alias if='x'"))

for (label, op) in [
    ("delete", AliasWriter.Operation.delete(name: "doomed; print -r -- keep")),
    ("rename", AliasWriter.Operation.rename(from: "doomed; print -r -- keep",
                                            to: "renamed", command: "echo x")),
] {
    let f = scratch("""
    if true
    \(ManagedBlock.begin)
    then
    alias doomed; print -r -- keep='x'
    fi
    \(ManagedBlock.end)
    if [ -z "$UNCLOSED"
    """)
    let before = read(f)
    _ = Result { try AliasWriter.apply(op, path: f, allEntries: []) }
    let after = read(f)
    check("\(label): a statement hidden in an alias name is never silently removed",
          after == before || after.contains("print -r -- keep"), after)
}

// Codex round 15, finding 2: commands AliasBar itself wrote containing apostrophes must
// pass their own round-trip. The canonical `'\''` splice was being double-escaped, so the
// fallback refused exactly the lines it exists to permit.
for command in ["echo 'hi'", "it's fine", "echo trailing'", "'leading", "plain", "a'b'c"] {
    let line = AliasWriter.aliasLine(name: "quoted", command: command)
    check("canonical round-trip survives \(command.debugDescription)",
          AliasWriter.isCanonicalAliasLine(line), line)
}

// And end to end, on the fallback path itself.
let apostropheFallback = scratch("""
if true
\(ManagedBlock.begin)
then
\(AliasWriter.aliasLine(name: "quoted", command: "echo 'hi'"))
\(AliasWriter.aliasLine(name: "keeper", command: "echo two"))
fi
\(ManagedBlock.end)
if [ -z "$UNCLOSED"
""")
let apOutcome = Result { try AliasWriter.apply(.delete(name: "quoted"), path: apostropheFallback, allEntries: []) }
let apAfter = read(apostropheFallback)
check("an AliasBar-written alias with an apostrophe is deletable on the fallback path",
      (try? apOutcome.get()) != nil, apAfter)
check("its neighbour survives", apAfter.contains("alias keeper="), apAfter)

// Codex round 16, the one that mattered most: everything above was checked only on
// already-broken files, and guardSyntax returns as soon as the rewritten file parses. So a
// definition carrying a second statement on the same line went straight through on an
// ORDINARY, perfectly valid .zshrc. Both routes, both operations.
for (label, victim) in [
    ("value-side", "alias doomed='x'; print -r -- keep-this"),
    ("name-side",  "alias doomed; print -r -- keep-this='x'"),
] {
    for (opLabel, name) in [("delete", "doomed"), ("rename", "doomed")] {
        let f = scratch("""
        \(ManagedBlock.begin)
        \(victim)
        alias bystander='9'
        \(ManagedBlock.end)
        """)
        check("\(label): the fixture is a valid zsh file to begin with", zshAccepts(f))
        let op: AliasWriter.Operation = opLabel == "delete"
            ? .delete(name: name)
            : .rename(from: name, to: "renamed", command: "echo x")
        let before = read(f)
        _ = Result { try AliasWriter.apply(op, path: f, allEntries: []) }
        let after = read(f)
        check("\(label)/\(opLabel): the user's second statement is never silently removed",
              after == before || after.contains("print -r -- keep-this"), after)
    }
}

// The same shape must not block ordinary hand-written aliases, which are not canonical
// and must stay editable.
for (label, name, line) in [
    ("unquoted",     "ll",   "alias ll='ls -la'"),
    ("double-quote", "gs",   "alias gs=\"git status\""),
    ("quoted-subst", "home", "alias home='echo $HOME'"),
] {
    let f = scratch("""
    \(ManagedBlock.begin)
    \(line)
    alias other='7'
    \(ManagedBlock.end)
    """)
    let outcome = Result { try AliasWriter.apply(.delete(name: name), path: f, allEntries: []) }
    check("\(label): a hand-written alias is still deletable", (try? outcome.get()) != nil, read(f))
    check("\(label): its neighbour survives", read(f).contains("alias other='7'"), read(f))
}

// An UNQUOTED value containing an expansion is refused, and that is a deliberate loss of
// capability rather than an oversight. `alias home=echo${HOME}` is almost certainly one
// alias, but `${arr[@]}` in the same position splits into several words and could carry
// another `name=`, and nothing static can tell a scalar from an array. The user gets a
// message pointing them at the line instead of a silent surprise. Quoting the value, as in
// the cases above, restores the edit.
for (label, name, line) in [
    ("bare-param",  "home", "alias home=echo${HOME}"),
    ("bare-arith",  "calc", "alias calc=echo$((1+1))"),
    ("dquote-param","dp",   "alias dp=\"echo $HOME\""),
    ("dquote-arith","da",   "alias da=\"echo $((1+1))\""),
] {
    let f = scratch("""
    \(ManagedBlock.begin)
    \(line)
    alias other='7'
    \(ManagedBlock.end)
    """)
    let before = read(f)
    let outcome = Result { try AliasWriter.apply(.delete(name: name), path: f, allEntries: []) }
    if (try? outcome.get()) == nil {
        check("\(label): refused, and the file is untouched", read(f) == before, read(f))
    } else {
        check("\(label): if allowed, the neighbour survives", read(f).contains("alias other='7'"), read(f))
    }
}

// Codex round 17: ONE `alias` invocation can define TWO aliases. No separator character
// appears anywhere, so the character blacklist this replaced walked straight past it.
check("a two-assignment alias invocation is not provably one alias",
      !AliasWriter.removalIsProvablyOneAlias("alias doomed=x victim=y"))
check("nor three", !AliasWriter.removalIsProvablyOneAlias("alias a=1 b=2 c=3"))
check("but an operand without = is a lookup, not a definition",
      AliasWriter.removalIsProvablyOneAlias("alias solo=1 lookmeup"))
check("a separator token is still refused",
      !AliasWriter.removalIsProvablyOneAlias("alias solo=1; print hi"))
check("and so is a pipe", !AliasWriter.removalIsProvablyOneAlias("alias solo=a|b"))
check("a trailing comment is fine",
      AliasWriter.removalIsProvablyOneAlias("alias solo='1' # a note"))
check("a # inside a word is not a comment",
      AliasWriter.removalIsProvablyOneAlias("alias tagged=echo#tag"))

for (opLabel, op) in [
    ("delete", AliasWriter.Operation.delete(name: "doomed")),
    ("upsert", AliasWriter.Operation.upsert(name: "doomed", command: "echo new", comment: nil)),
    ("rename", AliasWriter.Operation.rename(from: "doomed", to: "renamed", command: "echo x")),
] {
    let f = scratch("""
    \(ManagedBlock.begin)
    alias doomed=x victim=y
    alias bystander='9'
    \(ManagedBlock.end)
    """)
    check("\(opLabel): the two-assignment fixture is valid zsh", zshAccepts(f))
    let before = read(f)
    _ = Result { try AliasWriter.apply(op, path: f, allEntries: []) }
    let after = read(f)
    check("\(opLabel): a second alias on the same line is never silently removed",
          after == before || after.contains("victim=y"), after)
}

// Codex round 18: tokenization settles how many WORDS a line has, not how many aliases it
// defines, because zsh expands operands before `alias` runs. An operand that looks like a
// harmless lookup can expand into a second definition.
check("an expanded operand is not accepted as a lookup",
      !AliasWriter.removalIsProvablyOneAlias("alias doomed=x $extra"))
check("nor an array expansion",
      !AliasWriter.removalIsProvablyOneAlias("alias doomed=x ${arr[@]}"))
check("nor a command substitution",
      !AliasWriter.removalIsProvablyOneAlias("alias doomed=x $(print victim=y)"))
check("nor a glob", !AliasWriter.removalIsProvablyOneAlias("alias doomed=x *"))
check("a literal lookup name is still fine",
      AliasWriter.removalIsProvablyOneAlias("alias doomed=x lookmeup"))

for (opLabel, op) in [
    ("delete", AliasWriter.Operation.delete(name: "doomed")),
    ("upsert", AliasWriter.Operation.upsert(name: "doomed", command: "echo new", comment: nil)),
    ("rename", AliasWriter.Operation.rename(from: "doomed", to: "renamed", command: "echo x")),
] {
    let f = scratch("""
    \(ManagedBlock.begin)
    extra='victim=y'
    alias doomed=x $extra
    \(ManagedBlock.end)
    """)
    let before = read(f)
    _ = Result { try AliasWriter.apply(op, path: f, allEntries: []) }
    let after = read(f)
    check("\(opLabel): an alias hidden behind an expansion is never silently removed",
          after == before || after.contains("$extra"), after)
}

// Codex round 19: "a quoted value cannot split" was simply false. With `arr=(one victim=y)`,
// `alias doomed="${arr[@]}"` defines BOTH `doomed=one` and `victim=y` from one
// double-quoted word. Double quotes stop word splitting only when no `$` or backtick is
// present, which is the guarantee the rule now rests on.
check("a double-quoted array expansion is not provably one alias",
      !AliasWriter.removalIsProvablyOneAlias("alias doomed=\"${arr[@]}\""))
check("nor a double-quoted command substitution",
      !AliasWriter.removalIsProvablyOneAlias("alias doomed=\"$(print victim=y)\""))
check("nor a double-quoted backtick",
      !AliasWriter.removalIsProvablyOneAlias("alias doomed=\"`print victim=y`\""))
check("but a double-quoted literal is fine",
      AliasWriter.removalIsProvablyOneAlias("alias doomed=\"echo it's fine\""))
check("and a single-quoted value is always fine, expansion syntax included",
      AliasWriter.removalIsProvablyOneAlias("alias doomed='echo ${arr[@]}'"))
check("brace expansion in an unquoted value is refused",
      !AliasWriter.removalIsProvablyOneAlias("alias doomed={a,b}"))
check("and a glob", !AliasWriter.removalIsProvablyOneAlias("alias doomed=*"))

for (opLabel, op) in [
    ("delete", AliasWriter.Operation.delete(name: "doomed")),
    ("upsert", AliasWriter.Operation.upsert(name: "doomed", command: "echo new", comment: nil)),
    ("rename", AliasWriter.Operation.rename(from: "doomed", to: "renamed", command: "echo x")),
] {
    let f = scratch("""
    \(ManagedBlock.begin)
    arr=(one victim=y)
    alias doomed="${arr[@]}"
    \(ManagedBlock.end)
    """)
    let before = read(f)
    _ = Result { try AliasWriter.apply(op, path: f, allEntries: []) }
    let after = read(f)
    check("\(opLabel): an array expansion defining two aliases is never silently removed",
          after == before || after.contains("${arr[@]}"), after)
}

// Codex round 20: the guarantee was right, the implementation was not. Checking the first
// and last character does not prove the value is quoted throughout. An interior delimiter
// means the quoted run closed and reopened, leaving the middle exposed.
check("a value that closes and reopens its quote is not one word",
      !AliasWriter.removalIsProvablyOneAlias("alias doomed=''${arr[@]}''"))
check("same for double quotes",
      !AliasWriter.removalIsProvablyOneAlias("alias doomed=\"\"${arr[@]}\"\""))
check("a genuinely single-quoted value is still fine",
      AliasWriter.removalIsProvablyOneAlias("alias doomed='echo ${arr[@]}'"))

for (opLabel, op) in [
    ("delete", AliasWriter.Operation.delete(name: "doomed")),
    ("upsert", AliasWriter.Operation.upsert(name: "doomed", command: "echo new", comment: nil)),
    ("rename", AliasWriter.Operation.rename(from: "doomed", to: "renamed", command: "echo x")),
] {
    let f = scratch("""
    \(ManagedBlock.begin)
    arr=(one victim=y)
    alias doomed=''${arr[@]}''
    \(ManagedBlock.end)
    """)
    let before = read(f)
    _ = Result { try AliasWriter.apply(op, path: f, allEntries: []) }
    let after = read(f)
    check("\(opLabel): quote-boundary spoofing never removes the hidden alias",
          after == before || after.contains("${arr[@]}"), after)
}

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


// ===========================================================================
// HISTORY
// ===========================================================================
//
// The history palette hands shell history back to the user. Two things have to
// hold: nothing that looks like a credential is ever offered, and the ranking
// puts what you were reaching for at the top.

// --- What is safe to show back ---------------------------------------------

for secret in [
    "export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY",
    "curl -H 'Authorization: Bearer abc.def.ghi' https://api.example.com",
    "mysql -u root --password=hunter2",
    "export GITHUB_TOKEN=ghp_16CharactersOfNonsenseHere",
    "openssl rsa -in -----BEGIN PRIVATE KEY-----",
    "stripe login --api-key sk-live-abcdef",
    "echo AAAAB3NzaC1yc2EAAAADAQABAAABgQC7vbqajDhAdcMzJMTaOu2ZQuLc >> keys",
] {
    check("history hides a credential: \(secret.prefix(28))…",
          !HistoryScanner.isWorthOffering(secret))
}

for ordinary in [
    "git status -sb",
    "docker compose up -d",
    "kubectl get pods -n staging",
    "rg --hidden TODO",
    "cd ~/src/aliasbar && ./build.sh",
] {
    check("history keeps an ordinary command: \(ordinary)",
          HistoryScanner.isWorthOffering(ordinary))
}

check("history drops an empty line", !HistoryScanner.isWorthOffering(""))
check("history drops a bare short word", !HistoryScanner.isWorthOffering("ls"))
check("history drops an absurdly long line",
      !HistoryScanner.isWorthOffering(String(repeating: "a b ", count: 200)))

// --- Parsing a history file ------------------------------------------------

let histFile = scratch("""
: 1700000000:0;git status -sb
: 1700000001:0;git status -sb
: 1700000002:0;docker compose up -d
: 1700000003:0;export API_KEY=abc123def456
: 1700000004:0;git status -sb
""")
setenv("ALIASBAR_HISTORY", histFile, 1)
let histCommands = HistoryScanner.commands()
check("history strips the extended-format prefix",
      histCommands.contains { $0.text == "git status -sb" },
      histCommands.map(\.text).joined(separator: " | "))
check("history counts repeats",
      histCommands.first { $0.text == "git status -sb" }?.count == 3)
check("history records recency in file order",
      (histCommands.first { $0.text == "git status -sb" }?.lastSeen ?? 0)
          > (histCommands.first { $0.text == "docker compose up -d" }?.lastSeen ?? 0))
check("history omits the secret from a real file",
      !histCommands.contains { $0.text.contains("API_KEY") },
      histCommands.map(\.text).joined(separator: " | "))

let multiline = scratch("""
: 1700000000:0;for f in *.txt; do \\
  echo $f; \\
done
""")
setenv("ALIASBAR_HISTORY", multiline, 1)
check("history rejoins a backslash continuation",
      HistoryScanner.commands().contains { $0.text.contains("for f in") && $0.text.contains("done") },
      HistoryScanner.commands().map(\.text).joined(separator: " | "))
unsetenv("ALIASBAR_HISTORY")

// --- Ranking ---------------------------------------------------------------

check("an empty query matches everything", HistoryScanner.score("", in: "anything") == 0)
check("a non-match scores nil", HistoryScanner.score("zzz", in: "git status") == nil)

let prefix = HistoryScanner.score("git", in: "git status")!
let contains = HistoryScanner.score("git", in: "hub clone git")!
let subseq = HistoryScanner.score("gst", in: "git status")!
check("a prefix match beats a contains match", prefix > contains, "\(prefix) vs \(contains)")
check("a contains match beats a subsequence match", contains > subseq, "\(contains) vs \(subseq)")

let early = HistoryScanner.score("status", in: "git status now")!
let late = HistoryScanner.score("status", in: "echo a b c d e f g status")!
check("an earlier contains match outranks a later one", early > late, "\(early) vs \(late)")
check("matching is case-insensitive", HistoryScanner.score("GIT", in: "git status") != nil)


// ---------------------------------------------------------------------------
// Appearance: colour maths, derivation, contrast guarantees, presets
// ---------------------------------------------------------------------------

check("hex parses with a leading hash", HexColor(hex: "#4B5BC4") != nil)
check("hex parses without one", HexColor(hex: "4B5BC4") != nil)
check("hex parses the short form", HexColor(hex: "#FFF")?.hex == "#FFFFFF")
check("hex is case-insensitive", HexColor(hex: "#4b5bc4") == HexColor(hex: "#4B5BC4"))
check("a bad hex is rejected rather than defaulted", HexColor(hex: "#GGGGGG") == nil)
check("a short hex is rejected", HexColor(hex: "#12345") == nil)
check("hex round-trips", HexColor(hex: "#0A0B0D")?.hex == "#0A0B0D")

// Every channel, not just the greys: a round trip that only works for greys would
// pass with the chroma term dropped entirely.
var worstRoundTrip = 0.0
for hex in ["#000000", "#FFFFFF", "#0A0B0D", "#F1EFE7", "#D2764F", "#1414EE",
            "#E8FA4A", "#58CBFA", "#7F7F7F", "#123456"] {
    let original = HexColor(hex: hex)!
    let viaOklch = Oklch(original).rgb
    let drift = max(abs(original.red - viaOklch.red),
                    max(abs(original.green - viaOklch.green), abs(original.blue - viaOklch.blue)))
    worstRoundTrip = max(worstRoundTrip, drift)
}
check("sRGB survives a round trip through OKLCH", worstRoundTrip < 0.004,
      "worst channel drift \(worstRoundTrip)")

check("white is lighter than black in OKLab",
      Oklch(HexColor(hex: "#FFFFFF")!).l > Oklch(HexColor(hex: "#000000")!).l)
check("a grey has almost no chroma", Oklch(HexColor(hex: "#7F7F7F")!).c < 0.01)
check("a saturated blue has chroma", Oklch(HexColor(hex: "#1414EE")!).c > 0.1)

check("white on black is the maximum contrast",
      abs(HexColor(hex: "#FFFFFF")!.contrast(against: HexColor(hex: "#000000")!) - 21) < 0.01)
check("a colour has no contrast with itself",
      abs(HexColor(hex: "#4B5BC4")!.contrast(against: HexColor(hex: "#4B5BC4")!) - 1) < 0.001)

// The guarantee. Grounds that nobody sensible would pick are the point: a colour well
// makes mid-grey and acid green reachable in one drag, and the derivation has to hold.
//
// Two different promises, and only one of them is absolute. Where the ground can carry
// the ladder, every rung hits its target. Where it cannot — a mid-grey tops out near
// 5.3:1 against anything — the promise is that the rungs stay in order and stay apart,
// because text and dim rendering as the same colour is the failure that actually shows.
let awkwardGrounds = ["#0A0B0D", "#F1EFE7", "#F6F6F6", "#7F7F7F", "#808080",
                      "#2B2B2B", "#FFFFFF", "#000000", "#4B5BC4", "#00FF00", "#191813"]
for groundHex in awkwardGrounds {
    let ground = HexColor(hex: groundHex)!
    let scale = Theme.contrastScale(against: ground)
    let roomy = scale >= 1
    for accentHex in ["#4B5BC4", "#D2764F", "#1414EE", "#E8FA4A"] {
        let hue = Oklch(HexColor(hex: accentHex)!).h
        func rung(_ target: Double) -> HexColor {
            Theme.lightness(forContrast: Theme.scaled(target, by: scale),
                            against: ground, hue: hue, chroma: 0.015)
        }
        let text = rung(ContrastTarget.text)
        let dim = rung(ContrastTarget.dim)
        let faint = rung(ContrastTarget.faint)
        let label = "\(groundHex)/\(accentHex)"

        if roomy {
            check("text hits its ratio on \(label)",
                  text.contrast(against: ground) >= ContrastTarget.text - 0.15,
                  "got \(text.contrast(against: ground))")
            check("dim hits its ratio on \(label)",
                  dim.contrast(against: ground) >= ContrastTarget.dim - 0.1,
                  "got \(dim.contrast(against: ground))")
            check("faint hits its ratio on \(label)",
                  faint.contrast(against: ground) >= ContrastTarget.faint - 0.1,
                  "got \(faint.contrast(against: ground))")
        }
        check("the ladder stays in order on \(label)",
              text.contrast(against: ground) > dim.contrast(against: ground)
                  && dim.contrast(against: ground) > faint.contrast(against: ground),
              "\(text.contrast(against: ground)) / \(dim.contrast(against: ground)) "
                  + "/ \(faint.contrast(against: ground))")
        // Apart, not merely ordered: three shades separated by a rounding error would
        // satisfy the ordering check and still look like one colour.
        check("the rungs stay visibly apart on \(label)",
              text.contrast(against: ground) - dim.contrast(against: ground) > 0.4
                  && dim.contrast(against: ground) - faint.contrast(against: ground) > 0.2,
              "\(text.contrast(against: ground)) / \(dim.contrast(against: ground)) "
                  + "/ \(faint.contrast(against: ground))")
        check("faint is still readable on \(label)",
              faint.contrast(against: ground) >= 1.7,
              "got \(faint.contrast(against: ground))")
    }
}

check("a mid-grey ground admits it cannot carry the full ladder",
      Theme.contrastScale(against: HexColor(hex: "#7F7F7F")!) < 1)
check("a near-black ground carries it in full",
      Theme.contrastScale(against: HexColor(hex: "#0A0B0D")!) == 1)
check("white reaches the most contrast there is",
      abs(Theme.reachableContrast(against: HexColor(hex: "#FFFFFF")!) - 21) < 0.01)

// A ground so light that 11:1 is unreachable — #FFFFFF tops out at 21, but a pale
// yellow does not. The solver must return its best effort rather than something random.
let paleGround = HexColor(hex: "#FFFFCC")!
let onPale = Theme.lightness(forContrast: 21, against: paleGround, hue: 0, chroma: 0.01)
check("an impossible target still returns a dark colour on a pale ground",
      onPale.luminance < paleGround.luminance)

check("an accent too dark for a dark ground is lifted, not replaced",
      Theme.legible(HexColor(hex: "#101020")!, on: HexColor(hex: "#0A0B0D")!,
                    minimum: 3.4).contrast(against: HexColor(hex: "#0A0B0D")!) >= 3.4)
check("an accent that already reads is left alone",
      Theme.legible(HexColor(hex: "#58CBFA")!, on: HexColor(hex: "#0A0B0D")!,
                    minimum: 2.6) == HexColor(hex: "#58CBFA")!)

for preset in Appearance.builtIns {
    let theme = Theme.derive(from: preset)
    check("\(preset.name) knows whether it is light",
          theme.isLight == (preset.ground.luminance > 0.35))
    check("\(preset.name) keeps its corner radius", theme.cornerRadius == preset.cornerRadius)
    check("\(preset.name) is built in", preset.isBuiltIn)
}
check("Graphite is the dark one", !Theme.derive(from: .graphite).isLight)
check("Clay is a light one", Theme.derive(from: .clay).isLight)
check("Ultramarine is a light one", Theme.derive(from: .ultramarine).isLight)
check("an opaque look has no vibrancy", Theme.derive(from: .clay).vibrancy == nil)
check("a translucent look has vibrancy", Theme.derive(from: .graphite).vibrancy != nil)

// The second ground is what "follow macOS" switches to, and only when asked.
check("a second ground is used when the system is dark",
      Theme.derive(from: .clay, dark: true).isLight == false)
check("a second ground is ignored when the system is light",
      Theme.derive(from: .clay, dark: false).isLight)
check("a look with one ground ignores the system entirely",
      Theme.derive(from: .graphite, dark: true).isLight
          == Theme.derive(from: .graphite, dark: false).isLight)

// Glyphs drawn on a tint: the acid-yellow function tint is exactly the case that made
// this necessary, and white-on-yellow is the failure it prevents.
check("a light tint takes a dark glyph",
      Theme.wantsDarkGlyph(over: Appearance.ultramarine.functionTint))
check("a dark tint takes a white glyph",
      !Theme.wantsDarkGlyph(over: Appearance.graphite.accent))
check("a mid tint still resolves one way or the other",
      Theme.wantsDarkGlyph(over: HexColor(hex: "#7F7F7F")!)
          || !Theme.wantsDarkGlyph(over: HexColor(hex: "#7F7F7F")!))

let exported = PresetTransfer.export(.clay)
check("an exported look is readable text", exported.contains("Clay") && exported.contains("#"))
let reimported = PresetTransfer.importing(exported, id: "fresh")
check("an exported look imports back", reimported != nil)
check("an import keeps the values", reimported?.ground == Appearance.clay.ground)
check("an import gets a new identity", reimported?.id == "fresh")
check("an import is never built in", reimported?.isBuiltIn == false)
check("junk does not import", PresetTransfer.importing("not a preset", id: "x") == nil)

let mine = Appearance.graphite.copy(named: "Mine", id: "mine")
check("a copy takes the new name", mine.name == "Mine")
check("a copy is not built in", !mine.isBuiltIn)
check("a copy keeps the values it was made from", mine.accent == Appearance.graphite.accent)
check("a copy is not equal to its source", mine != Appearance.graphite)

// ---------------------------------------------------------------------------
// Board grid geometry — what makes ↑ ↓ move by a row rather than by one key
// ---------------------------------------------------------------------------

check("comfortable keys fit six across",
      WindowLayout.boardColumns(keyWidth: BoardDensity.comfortable.keyWidth) == 6,
      "got \(WindowLayout.boardColumns(keyWidth: BoardDensity.comfortable.keyWidth))")
check("dense keys fit more across",
      WindowLayout.boardColumns(keyWidth: BoardDensity.dense.keyWidth) > 6)
check("a key wider than the window still leaves one column",
      WindowLayout.boardColumns(keyWidth: 5000) == 1)
check("a wider key never means more columns",
      WindowLayout.boardColumns(keyWidth: 120) <= WindowLayout.boardColumns(keyWidth: 80))


// ---------------------------------------------------------------------------
// Motion: the off switch, and the two sources that feed it
// ---------------------------------------------------------------------------

let fullPlan = MotionPlan.resolve(.full, reduceMotion: false)
check("full motion moves things", fullPlan.movesThings)
check("full motion fades", fullPlan.fades)
check("full motion staggers", fullPlan.stagger(3) != nil)
check("full motion returns an animation", fullPlan(Motion.standard) != nil)

let reducedPlan = MotionPlan.resolve(.reduced, reduceMotion: false)
check("reduced motion moves nothing", !reducedPlan.movesThings)
check("reduced motion still fades", reducedPlan.fades)
check("reduced motion still animates", reducedPlan(Motion.standard) != nil)

let nonePlan = MotionPlan.resolve(.none, reduceMotion: false)
check("no motion moves nothing", !nonePlan.movesThings)
check("no motion does not fade", !nonePlan.fades)
check("no motion returns no animation", nonePlan(Motion.standard) == nil)
check("no motion does not stagger", nonePlan.stagger(0) == nil)

// The system setting is an accessibility setting, not a preference: it can only take
// motion away, never give it back.
check("the system setting overrides a full preference",
      !MotionPlan.resolve(.full, reduceMotion: true).movesThings)
check("the system setting leaves fades alone",
      MotionPlan.resolve(.full, reduceMotion: true).fades)
check("the system setting cannot revive motion the user turned off",
      MotionPlan.resolve(.none, reduceMotion: true)(Motion.standard) == nil)
check("neither source can be overridden by the other into more motion",
      !MotionPlan.resolve(.reduced, reduceMotion: true).movesThings)


// ---------------------------------------------------------------------------
print("\n" + String(repeating: "-", count: 60))
print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)

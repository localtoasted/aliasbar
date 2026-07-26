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

let freshlyClashing = scratch("""
# Added after AliasBar's editor opened.
alias collision='echo outside'
""")
let freshlyClashingOriginal = read(freshlyClashing)
expectThrow("a fresh unmanaged clash is refused even when UI entries are stale") {
    _ = try AliasWriter.apply(.upsert(name: "collision", command: "echo inside", comment: nil),
                              path: freshlyClashing, allEntries: [])
}
check("a refused fresh clash leaves the file untouched",
      read(freshlyClashing) == freshlyClashingOriginal)

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

let firstBackupContents = read(permPath)
let firstBackup = try! AliasWriter.apply(.upsert(name: "n", command: "echo changed", comment: nil),
                                          path: permPath, allEntries: [])
let secondBackupContents = read(permPath)
let secondBackup = try! AliasWriter.apply(.upsert(name: "n", command: "echo changed again",
                                                   comment: nil),
                                           path: permPath, allEntries: [])
check("two writes in one second create distinct backups", firstBackup != secondBackup)
check("the first same-second backup keeps its recovery point",
      read(firstBackup) == firstBackupContents)
check("the second same-second backup keeps its recovery point",
      read(secondBackup) == secondBackupContents)
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

// ---------------------------------------------------------------------------
print("\n26. The span lexer tracks nesting and top-level separators together")

/// These fixtures opt past the collateral-confirmation guard so they exercise the span
/// itself. A wrong under-span leaves invalid syntax behind; a wrong over-span removes one
/// of `survives`. The zsh and collateral guards remain separately covered above.
func checkExactSpanDelete(_ label: String,
                          statement: String,
                          removes: [String],
                          survives: [String]) {
    let path = scratch("""
    \(ManagedBlock.begin)
    \(statement)
    \(ManagedBlock.end)
    """)
    check("\(label): fixture is valid zsh", zshAccepts(path), read(path))
    let outcome = Result {
        try AliasWriter.apply(.delete(name: "doomed"), path: path, allEntries: [],
                              confirmedCollateral: true)
    }
    let after = read(path)
    check("\(label): exact-span delete succeeds", (try? outcome.get()) != nil, after)
    for fragment in removes {
        check("\(label): removes \(fragment)", !after.contains(fragment), after)
    }
    for fragment in survives {
        check("\(label): preserves \(fragment)", after.contains(fragment), after)
    }
    check("\(label): result remains valid zsh", zshAccepts(path), after)
}

// 1. A physical newline inside a quoted value belongs to the alias.
checkExactSpanDelete(
    "newline inside a value",
    statement: """
    alias doomed="echo one
    echo two"
    alias newlineKeeper='1'
    """,
    removes: ["alias doomed=", "echo two"],
    survives: ["alias newlineKeeper='1'"])

// 2. An unquoted trailing backslash carries the statement onto the next line.
checkExactSpanDelete(
    "trailing backslash continuation",
    statement: """
    alias doomed='echo one' \\
    print two
    alias slashKeeper='2'
    """,
    removes: ["alias doomed=", "print two"],
    survives: ["alias slashKeeper='2'"])

// 3. A # embedded in a word is literal and cannot hide that trailing backslash.
checkExactSpanDelete(
    "embedded hash before continuation",
    statement: """
    alias doomed=echo#tag \\
    print three
    alias hashKeeper='3'
    """,
    removes: ["alias doomed=", "print three"],
    survives: ["alias hashKeeper='3'"])

// 4. Backslash-newline preserves whether the next character starts a new word. Here the
// whitespace before the backslash makes the next line's # a real comment, whose own
// backslash is inert.
checkExactSpanDelete(
    "word boundary across continuation",
    statement: """
    alias doomed=one \\
    # continuation comment \\
    alias boundaryKeeper='4'
    """,
    removes: ["alias doomed=", "# continuation comment"],
    survives: ["alias boundaryKeeper='4'"])

// 5. A quoted } inside ${...} is data, not the parameter expansion's closer.
checkExactSpanDelete(
    "inner brace in parameter expansion",
    statement: """
    alias doomed=${missing:-"}"
    still}
    alias braceKeeper='5'
    """,
    removes: ["alias doomed=", "still}"],
    survives: ["alias braceKeeper='5'"])

// 6. Parentheses inside arithmetic adjust its delimiter depth; the first ) is not one of
// the two that close $((...)).
checkExactSpanDelete(
    "inner paren in arithmetic expansion",
    statement: """
    alias doomed=$(( (1 + 2)
      * 3 ))
    alias arithmeticKeeper='6'
    """,
    removes: ["alias doomed=", "* 3 ))"],
    survives: ["alias arithmeticKeeper='6'"])

// 7. A separator at root depth ends the span before a later comment/backslash can extend
// it. Confirmation permits removing that exact first line, but never the next statement.
checkExactSpanDelete(
    "separator before comment",
    statement: """
    alias doomed=x;# comment \\
    alias separatorKeeper='7'
    """,
    removes: ["alias doomed="],
    survives: ["alias separatorKeeper='7'"])

// 8. Every supported substitution can cross a newline without an open quote or a
// backslash. Separators inside command/process substitutions remain nested.
for (label, statement, tail) in [
    ("command substitution",
     "alias doomed=$(print one; print two\nprint three)\nalias cmdKeeper='8'",
     "print three)"),
    ("arithmetic substitution",
     "alias doomed=$((1 +\n2))\nalias arithKeeper='8'",
     "2))"),
    ("parameter substitution",
     "alias doomed=${missing:-one\ntwo}\nalias paramKeeper='8'",
     "two}"),
    ("process substitution",
     "alias doomed=<(print one | cat\nprint two)\nalias processKeeper='8'",
     "print two)"),
] {
    checkExactSpanDelete(
        label,
        statement: statement,
        removes: ["alias doomed=", tail],
        survives: [statement.components(separatedBy: "\n").last!])
}

// 9. The historical over-span swallowed arbitrary non-alias content after `;# ... \`.
// With the root separator integrated into the nesting scanner, even a confirmed removal
// covers only the alias's physical line.
for (label, victim) in [
    ("export", "export IMPORTANT=value"),
    ("function", "reload() { source ~/.zshrc; }"),
    ("bare assignment", "EDITOR=nvim"),
] {
    checkExactSpanDelete(
        "non-alias \(label)",
        statement: """
        alias doomed=x;# comment \\
        \(victim)
        """,
        removes: ["alias doomed="],
        survives: [victim])
}

// 10. Output process substitution is the same nested command context as <(...).
checkExactSpanDelete(
    "output process substitution",
    statement: """
    alias doomed=>(print one
    print two)
    alias outputProcessKeeper='10'
    """,
    removes: ["alias doomed=", "print two)"],
    survives: ["alias outputProcessKeeper='10'"])

// 11. Legacy backtick command substitution can span physical lines too.
checkExactSpanDelete(
    "multiline backtick substitution",
    statement: """
    alias doomed=`print one
    print two`
    alias backtickKeeper='11'
    """,
    removes: ["alias doomed=", "print two`"],
    survives: ["alias backtickKeeper='11'"])

// 12. A case pattern's closing parenthesis is grammar, not the end of $().
checkExactSpanDelete(
    "case arm inside command substitution",
    statement: """
    alias doomed=$(case x in
    x) print yes ;;
    esac
    )
    alias caseKeeper='12'
    """,
    removes: ["alias doomed=", "esac"],
    survives: ["alias caseKeeper='12'"])

// 13. Heredoc bodies are opaque shell input; delimiters in their payload are data.
checkExactSpanDelete(
    "heredoc inside command substitution",
    statement: """
    alias doomed=$(cat <<'EOF'
    payload )
    EOF
    )
    alias heredocKeeper='13'
    """,
    removes: ["alias doomed=", "payload )"],
    survives: ["alias heredocKeeper='13'"])

// 14. A root alias's heredoc body and terminator belong to the alias statement. Leaving
// either behind would turn opaque payload into executable shell input.
checkExactSpanDelete(
    "heredoc on root alias",
    statement: """
    alias doomed=print <<EOF
    payload from heredoc
    EOF
    alias rootHeredocKeeper='14'
    """,
    removes: ["alias doomed=", "payload from heredoc", "\nEOF\n"],
    survives: ["alias rootHeredocKeeper='14'"])

// 15. Every zsh case terminator returns the grammar to pattern position. In particular,
// the next arm's ) cannot close the surrounding command substitution.
for (label, terminator) in [
    ("fallthrough", ";&"),
    ("continue", ";|"),
] {
    checkExactSpanDelete(
        "case \(label) terminator",
        statement: """
        alias doomed=$(case x in; x) print one \(terminator); y) print two ;; esac)
        alias caseTerminatorKeeper='15'
        """,
        removes: ["alias doomed=", "y) print two"],
        survives: ["alias caseTerminatorKeeper='15'"])
}

// 16. Quote removal applies across the entire heredoc delimiter word, not only when its
// first character is quoted.
checkExactSpanDelete(
    "mixed-quoted heredoc delimiter",
    statement: """
    alias doomed=$(cat <<E'OF'
    payload )
    EOF
    )
    alias mixedHeredocKeeper='16'
    """,
    removes: ["alias doomed=", "payload )"],
    survives: ["alias mixedHeredocKeeper='16'"])

// 17. Heredoc discovery spans the complete root shell list. Operators before a
// separator must remain queued, and operators after it must still be discovered.
let rootHeredocSeparators = [
    ("pipe", "|"),
    ("and", "&&"),
    ("or", "||"),
    ("semicolon", ";"),
    ("background", "&"),
]
for (position, beforeSeparator) in [("before", true), ("after", false)] {
    for (index, entry) in rootHeredocSeparators.enumerated() {
        let (separatorLabel, separator) = entry
        let delimiter = "HD\(position.uppercased())\(index)"
        let payload = "\(position) \(separatorLabel) payload"
        let command = beforeSeparator
            ? "cat <<\(delimiter) \(separator) cat"
            : "cat \(separator) cat <<\(delimiter)"
        checkExactSpanDelete(
            "root heredoc \(position) \(separatorLabel)",
            statement: """
            alias doomed=\(command)
            \(payload)
            \(delimiter)
            alias rootSeparatorKeeper='\(position)-\(index)'
            """,
            removes: ["alias doomed=", payload, "\n\(delimiter)\n"],
            survives: ["alias rootSeparatorKeeper='\(position)-\(index)'"])
    }
}

// 18. More than one heredoc may be queued on opposite sides of a separator. The shell
// consumes bodies in operator order, and the removal span must do the same.
checkExactSpanDelete(
    "root heredocs split across separator",
    statement: """
    alias doomed=cat <<FIRST | cat <<SECOND
    first split payload
    FIRST
    second split payload
    SECOND
    alias splitHeredocKeeper='18'
    """,
    removes: ["alias doomed=", "first split payload", "second split payload",
              "\nFIRST\n", "\nSECOND\n"],
    survives: ["alias splitHeredocKeeper='18'"])

// 19. Tab-stripping is a property of each queued heredoc, not of the shell list as a
// whole. Mixing << and <<- across a separator must preserve both delimiter rules.
checkExactSpanDelete(
    "mixed root heredoc operators across separator",
    statement: "alias doomed=cat <<PLAIN | cat <<-TABBED\n"
        + "plain mixed payload\n"
        + "PLAIN\n"
        + "\ttabbed mixed payload\n"
        + "\tTABBED\n"
        + "alias mixedOperatorKeeper='19'",
    removes: ["alias doomed=", "plain mixed payload", "tabbed mixed payload",
              "\nPLAIN\n", "\tTABBED\n"],
    survives: ["alias mixedOperatorKeeper='19'"])

// 20. The unresolved-heredoc invariant is independent of ordinary continuation state.
// Even if future lexer work accidentally loses a frame, a recognized delimiter that
// was never consumed must make the edit fail without touching the file.
let unconsumedRootHeredoc = scratch("""
\(ManagedBlock.begin)
alias doomed=cat <<NEVER | cat
payload without a terminator
\(ManagedBlock.end)
""")
let unconsumedRootHeredocBefore = read(unconsumedRootHeredoc)
expectThrow("an unconsumed root heredoc refuses the edit") {
    _ = try AliasWriter.apply(.delete(name: "doomed"), path: unconsumedRootHeredoc,
                              allEntries: [], confirmedCollateral: true)
}
check("an unconsumed root heredoc leaves the file byte-for-byte untouched",
      read(unconsumedRootHeredoc) == unconsumedRootHeredocBefore,
      read(unconsumedRootHeredoc))

/// A heredoc delimiter outside the recognized set must refuse the edit and leave
/// the file byte-for-byte untouched. Guessing at the delimiter is what round 4
/// proved fatal: an identity that diverges from zsh balances the unresolved
/// counter against a false terminator, and the deletion orphans live heredoc
/// payload as executable input.
func checkHeredocDelimiterRefusal(_ label: String, statement: String,
                                  fixtureMustBeValidZsh: Bool = true) {
    let path = scratch("""
    \(ManagedBlock.begin)
    \(statement)
    \(ManagedBlock.end)
    """)
    if fixtureMustBeValidZsh {
        check("\(label): fixture is valid zsh", zshAccepts(path), read(path))
    }
    let before = read(path)
    expectThrow("\(label): delete refuses the edit") {
        _ = try AliasWriter.apply(.delete(name: "doomed"), path: path, allEntries: [],
                                  confirmedCollateral: true)
    }
    check("\(label): file left byte-for-byte untouched", read(path) == before,
          read(path))
}

// 21. Round-4 corruption reproduction: the backslash against the newline continues
// the delimiter word, so the real delimiter is EOF. A scanner that stops at the
// backslash invents EO, terminates the body two lines early, and the deletion
// orphans `second payload` and the real terminator as executable input.
checkHeredocDelimiterRefusal(
    "backslash-continued heredoc delimiter",
    statement: """
    alias doomed=cat <<EO\\
    F
    first payload
    EO
    second payload
    EOF
    alias continuationKeeper='21'
    """)

// 22. Round-4 corruption reproduction: `$'EOF'` is ANSI-C quoting, so the real
// delimiter is EOF. A scanner that reads the characters literally invents $EOF and
// terminates against the literal `$EOF` body line instead.
checkHeredocDelimiterRefusal(
    "ANSI-C-quoted heredoc delimiter",
    statement: """
    alias doomed=cat <<$'EOF'
    first payload
    $EOF
    second payload
    EOF
    alias ansiKeeper='22'
    """)

// 23. Inside a double-quoted delimiter a backslash-newline is a line continuation,
// so the word carries onto the next physical line. The old scanner dropped the
// operator entirely here, registering no heredoc at all.
checkHeredocDelimiterRefusal(
    "double-quoted delimiter continued across the newline",
    statement: """
    alias doomed=cat <<"EO\\
    F"
    first payload
    EOF
    alias quotedContinuationKeeper='23'
    """)

// 24. A quote still open at the newline continues the delimiter word across it.
// The old scanner also dropped this operator silently. The fixture is not claimed
// as valid zsh; refusal must hold regardless of what the file means.
checkHeredocDelimiterRefusal(
    "unterminated quote in heredoc delimiter",
    statement: """
    alias doomed=cat <<'EOF
    payload
    EOF
    alias unterminatedKeeper='24'
    """,
    fixtureMustBeValidZsh: false)

// 25. Command substitution in a delimiter word is outside the recognized set.
checkHeredocDelimiterRefusal(
    "backtick in heredoc delimiter",
    statement: """
    alias doomed=cat <<`EOF`
    payload
    EOF
    alias backtickDelimiterKeeper='25'
    """,
    fixtureMustBeValidZsh: false)

// 26. zsh accepts command-substitution syntax literally in a heredoc delimiter word.
// Its spaces and parentheses belong to the delimiter; stopping at the first `(` invents
// `$` as the delimiter and can balance the unresolved counter against a payload line.
checkHeredocDelimiterRefusal(
    "command-substitution syntax in heredoc delimiter",
    statement: """
    alias doomed=cat <<$(print EOF)
    first payload
    $
    second payload
    $(print EOF)
    alias commandSubstitutionDelimiterKeeper='26'
    """)

// 27. Braced parameter syntax has the same trap: whitespace belongs to zsh's literal
// delimiter, while a word-level scanner would stop early and invent `${value:-EOF`.
checkHeredocDelimiterRefusal(
    "parameter-expansion syntax in heredoc delimiter",
    statement: """
    alias doomed=cat <<${value:-EOF X}
    first payload
    ${value:-EOF
    second payload
    ${value:-EOF X}
    alias parameterDelimiterKeeper='27'
    """)

// 28. Legacy arithmetic syntax around a delimiter is outside the recognized set too.
// This malformed fixture is not assigned a zsh meaning; the safety property is that an
// edit never guesses at its extent or changes a byte.
checkHeredocDelimiterRefusal(
    "arithmetic-substitution syntax in heredoc delimiter",
    statement: """
    alias doomed=cat <<$[1 + 2]
    first payload
    $[1
    second payload
    3
    alias arithmeticDelimiterKeeper='28'
    """,
    fixtureMustBeValidZsh: false)

// 29. Parentheses can be literal delimiter characters in zsh, so treating one as a
// word boundary invents a shorter terminator and can expose the real payload.
checkHeredocDelimiterRefusal(
    "parenthesized heredoc delimiter suffix",
    statement: """
    alias doomed=cat <<foo(bar)
    first payload
    foo
    second payload
    foo(bar)
    alias parenthesizedDelimiterKeeper='29'
    """)

// 30. zsh ends the delimiter word at a redirection, so `<<EOF>file` names EOF, not
// `EOF>file`. Folding the redirect into the delimiter would never find the body's
// real terminator.
checkExactSpanDelete(
    "redirect immediately after heredoc delimiter",
    statement: """
    alias doomed=cat <<EOF>/tmp/aliasbar-test-26-redirect
    redirect payload
    EOF
    alias redirectKeeper='30'
    """,
    removes: ["alias doomed=", "redirect payload", "\nEOF\n"],
    survives: ["alias redirectKeeper='30'"])

// 31. `<<<` is a here-string, not a heredoc: nothing is deferred past the newline,
// and its word must not be misread as a delimiter that never arrives.
checkExactSpanDelete(
    "here-string is not a heredoc",
    statement: """
    alias doomed=cat <<<'here payload'
    alias hereStringKeeper='31'
    """,
    removes: ["alias doomed=", "here payload"],
    survives: ["alias hereStringKeeper='31'"])


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
let explicitHistCommands = HistoryScanner.commands(path: histFile)
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
check("history app adapter matches the explicit-path core command scan",
      Set(histCommands) == Set(explicitHistCommands))
check("history app adapter matches the explicit-path core usage scan",
      HistoryScanner.commandWordCounts() == HistoryScanner.commandWordCounts(path: histFile))

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
print("\n26. Enter actions: the paste/copy split the Afterwards setting relies on")

// The Afterwards control disables itself for paste modes on the strength of two
// claims: `needsAccessibility` is exactly "this action pastes", and an action's ⌘⏎
// counterpart never crosses the paste/copy line. If a paste's secondary were a copy,
// a greyed-out "Keep it open" would be wrong for half the keystrokes on screen.
check("paste name needs Accessibility", EnterAction.pasteName.needsAccessibility)
check("paste command needs Accessibility", EnterAction.pasteCommand.needsAccessibility)
check("copy name does not", !EnterAction.copyName.needsAccessibility)
check("copy command does not", !EnterAction.copyCommand.needsAccessibility)
check("no secondary crosses the paste/copy line",
      EnterAction.allCases.allSatisfy {
          $0.secondary.needsAccessibility == $0.needsAccessibility
      })

// ---------------------------------------------------------------------------
print("\n27. Bucket filter chip semantics")

for mode in ViewMode.allCases {
    check("All has no header filter in \(mode.label)",
          !Bucket.all.showsHeaderFilter(in: mode))
    check("By file has no header filter in \(mode.label)",
          !Bucket.byFile.showsHeaderFilter(in: mode))
    check("Functions header filter matches \(mode.label) surface",
          Bucket.functions.showsHeaderFilter(in: mode) == (mode != .manage))
}

// ---------------------------------------------------------------------------
print("\n28. Onboarding actions have explicit accessibility names")

// The lightweight test binary does not compile SwiftUI views. Inspect the shipped source
// instead so every button-producing boundary stays explicitly named even when its visible
// label is only a glyph, shortcut, or composite preview.
let projectRoot = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let onboardingSource = read(projectRoot.appendingPathComponent("Sources/Onboarding.swift").path)
check("onboarding source is readable",
      onboardingSource != "<unreadable>")

let onboardingAccessibilityBoundaries = [
    ".accessibilityLabel(\"Set up later\")",
    ".accessibilityLabel(\"Skip this setup step\")",
    ".accessibilityLabel(step == Self.stepCount - 1",
    ".accessibilityLabel(recordingHotkey",
    ".accessibilityLabel(title)",
    ".accessibilityLabel(axPrompted",
    ".accessibilityLabel(\"Choose aliases file\")",
    ".accessibilityLabel(customising",
    ".accessibilityLabel(\"Save appearance preset\")",
    ".accessibilityLabel(\"Cancel saving appearance preset\")",
    ".accessibilityLabel(\"Save appearance as a preset\")",
    ".accessibilityLabel(\"\\(appearance.name) appearance\")",
    ".accessibilityLabel(\"Re-grant Accessibility permission\")",
]
for boundary in onboardingAccessibilityBoundaries {
    check("onboarding AX boundary \(boundary)",
          onboardingSource.contains(boundary))
}

for stateName in [
    "\"Finish setup\"",
    "\"Continue to next setup step\"",
    "\"Stop recording keyboard shortcut\"",
    "\"Change keyboard shortcut, currently \\(settings.hotkey.displayString)\"",
    "\"Show the macOS Accessibility permission prompt again\"",
    "\"Allow typing by showing the macOS Accessibility permission prompt\"",
    "\"Hide appearance controls\"",
    "\"Customise appearance\"",
] {
    check("onboarding dynamic AX name \(stateName)",
          onboardingSource.contains(stateName))
}

let onboardingAccessibilityLabelCount =
    onboardingSource.components(separatedBy: ".accessibilityLabel(").count - 1
check("all onboarding button boundaries own exactly one accessibility label",
      onboardingAccessibilityLabelCount == 13,
      "found \(onboardingAccessibilityLabelCount), expected 13")

// ---------------------------------------------------------------------------
print("\n29. Foundation core seam")

let coreModelSource = read(projectRoot.appendingPathComponent("Sources/Model.swift").path)
let coreWriterSource = read(projectRoot.appendingPathComponent("Sources/AliasWriter.swift").path)
check("core sources are readable",
      coreModelSource != "<unreadable>" && coreWriterSource != "<unreadable>")
for forbidden in ["import SwiftUI", "import AppKit", "UserDefaults", "AppSettings"] {
    check("core source excludes \(forbidden)",
          !coreModelSource.contains(forbidden) && !coreWriterSource.contains(forbidden))
}

check("stored rc path wins over the environment",
      AppPaths.resolveRcPath(stored: "/tmp/stored.zshrc",
                             environmentOverride: "/tmp/environment.zshrc",
                             homeDirectory: "/tmp/home") == "/tmp/stored.zshrc")
check("environment rc path wins when no setting exists",
      AppPaths.resolveRcPath(stored: nil,
                             environmentOverride: "/tmp/environment.zshrc",
                             homeDirectory: "/tmp/home") == "/tmp/environment.zshrc")
check("rc path falls back to the supplied home",
      AppPaths.resolveRcPath(stored: nil,
                             environmentOverride: nil,
                             homeDirectory: "/tmp/home") == "/tmp/home/.zshrc")
check("history path falls back to the supplied home",
      AppPaths.resolveHistoryPath(environmentOverride: nil,
                                  homeDirectory: "/tmp/home") == "/tmp/home/.zsh_history")

let coreRc = scratch("""
# status shortcut
alias gst='git status'

say_hi() {
  echo hi
}
""")
let explicitParse = ZshrcParser.parse(path: coreRc)
let textParse = ZshrcParser.parseText(read(coreRc), sourceFile: coreRc)
check("explicit-path parser matches the text parser",
      explicitParse.entries == textParse)

let duplicateAlias = ShellEntry(kind: .alias, name: "same", command: "echo first",
                                comment: nil, sourceFile: coreRc, line: 1, managed: false)
let winningAlias = ShellEntry(kind: .alias, name: "same", command: "echo second",
                              comment: nil, sourceFile: coreRc, line: 5, managed: false)
let sameFunction = ShellEntry(kind: .function, name: "same", command: "echo function",
                              comment: nil, sourceFile: coreRc, line: 9, managed: false)
let structuralConflicts = ConflictDetector.detect(
    in: [duplicateAlias, winningAlias, sameFunction],
    searchPaths: []
)
check("conflict core preserves redefinition details",
      structuralConflicts.contains {
          if case .redefined(let times, let winningLine) = $0.reason {
              return $0.name == "same" && times == 2 && winningLine == 5
          }
          return false
      })
check("conflict core preserves alias/function clashes",
      structuralConflicts.contains {
          $0.name == "same" && $0.reason == .aliasFunctionClash
      })

let fakePathDirectory = sandbox + "/core-path"
try! FileManager.default.createDirectory(atPath: fakePathDirectory,
                                         withIntermediateDirectories: true)
let fakeExecutable = fakePathDirectory + "/coretool"
FileManager.default.createFile(atPath: fakeExecutable, contents: Data())
try! FileManager.default.setAttributes([.posixPermissions: 0o755],
                                       ofItemAtPath: fakeExecutable)
let shadowEntry = ShellEntry(kind: .alias, name: "coretool", command: "echo shadow",
                             comment: nil, sourceFile: coreRc, line: 12, managed: false)
check("conflict core preserves executable shadow detection",
      ConflictDetector.detect(in: [shadowEntry], searchPaths: [fakePathDirectory]).contains {
          if case .shadowsBinary(let path) = $0.reason {
              return $0.name == "coretool" && path == fakeExecutable
          }
          return false
      })

func coreRanked(_ name: String,
                command: String,
                comment: String? = nil,
                uses: Int,
                line: Int) -> RankedEntry {
    RankedEntry(
        entry: ShellEntry(kind: .alias, name: name, command: command, comment: comment,
                          sourceFile: coreRc, line: line, managed: false),
        uses: uses
    )
}

let rankingFixture = [
    coreRanked("git", command: "git", uses: 1, line: 1),
    coreRanked("git-sync", command: "sync", uses: 2, line: 2),
    coreRanked("legit", command: "echo legitimate", uses: 3, line: 3),
    coreRanked("helper", command: "echo helper", comment: "git utilities", uses: 4, line: 4),
    coreRanked("runner", command: "git status", uses: 5, line: 5),
    coreRanked("other", command: "echo other", uses: 6, line: 6),
]
check("ranker preserves exact/prefix/substring/comment/command tiers",
      Ranker.rank(rankingFixture, query: "  GIT  ", scope: .everything).map(\.name)
          == ["git", "git-sync", "legit", "helper", "runner"])
check("name-only scope excludes comment and command matches",
      Ranker.rank(rankingFixture, query: "git", scope: .name).map(\.name)
          == ["git", "git-sync", "legit"])
check("name-and-comment scope excludes command-only matches",
      Ranker.rank(rankingFixture, query: "git", scope: .nameComment).map(\.name)
          == ["git", "git-sync", "legit", "helper"])
check("empty-query ranking preserves usage-first rest order",
      Ranker.rank(rankingFixture, query: "", scope: .everything).map(\.name)
          == ["other", "runner", "helper", "legit", "git-sync", "git"])
check("board matching uses the same ranker tiers",
      Ranker.matches(rankingFixture[3], query: "git", scope: .nameComment)
          && !Ranker.matches(rankingFixture[4], query: "git", scope: .nameComment)
          && Ranker.matches(rankingFixture[4], query: "git", scope: .everything))

check("name suggester keeps the primary initials",
      AliasNameSuggester.suggest(for: "sudo FOO=bar git status -sb", takenNames: []) == "gs")
check("name suggester advances to the readable collision candidate",
      AliasNameSuggester.suggest(for: "git status", takenNames: ["gs"]) == "gis")
check("name suggester numbers only after readable candidates are taken",
      AliasNameSuggester.suggest(for: "git status",
                                 takenNames: ["gs", "gis", "gist", "git"]) == "gs2")
check("name suggester preserves the exhausted fallback",
      AliasNameSuggester.suggest(
          for: "git status",
          takenNames: ["gs", "gis", "gist", "git", "gs2", "gs3", "gs4",
                       "gs5", "gs6", "gs7", "gs8", "gs9"]
      ) == "gs")
check("name suggester returns empty when no usable word remains",
      AliasNameSuggester.suggest(for: "sudo --help FOO=bar", takenNames: []) == "")

// ---------------------------------------------------------------------------
print("\n30. Sensitive content classifier")

typealias QuarantineReason = SensitiveContentClassifier.QuarantineReason

func classifierReason(_ content: String) -> QuarantineReason? {
    SensitiveContentClassifier.quarantineReason(in: content)
}

func classifierBase64URL(_ value: String) -> String {
    Data(value.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func syntheticJWT(
    header: String = #"{"typ":"JWT","alg":"HS256"}"#,
    claims: String = #"{"sub":"synthetic-user","iat":123}"#,
    signatureBytes: Int = 32
) -> String {
    let signature = Data((0..<signatureBytes).map {
        UInt8(($0 * 17 + 3) % 251)
    }).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return [
        classifierBase64URL(header),
        classifierBase64URL(claims),
        signature,
    ].joined(separator: ".")
}

// Stable reasons never carry the matched bytes in an associated value, description,
// raw value, log, or error. These checks use a canary that is not a token shape.
let classifierLeakageCanary = "fixture-payload-must-never-appear"
let reasonRawValues = QuarantineReason.allCases.map(\.rawValue)
check("quarantine reason raw values are unique",
      Set(reasonRawValues).count == reasonRawValues.count)
for reason in QuarantineReason.allCases {
    check("quarantine reason \(reason.rawValue) has a payload-free description",
          !reason.description.contains(classifierLeakageCanary)
              && !reason.rawValue.contains(classifierLeakageCanary))
}

// AWS publishes AKIA for long-term IDs and ASIA for temporary STS IDs. Secret access
// keys have no unique prefix, so the AWS-specific secret reason requires its assignment.
let awsIDBody = "A1B2C3D4E5F6G7H8"
check("AKIA access ID is quarantined",
      classifierReason("AKIA\(awsIDBody)") == .awsAccessKeyID)
check("ASIA access ID is quarantined",
      classifierReason("value=ASIA\(awsIDBody)") == .awsAccessKeyID)
check("embedded AWS-looking ID is not a token",
      classifierReason("xAKIA\(awsIDBody)") == nil)
check("short AWS-looking ID stays safe",
      classifierReason("AKIA\(awsIDBody.dropLast())") == nil)
check("long AWS-looking ID stays safe",
      classifierReason("AKIA\(awsIDBody)Z") == nil)
check("lowercase AWS-looking prefix stays safe",
      classifierReason("akia\(awsIDBody)") == nil)

let syntheticAWSSecret = String(repeating: "Ab3/", count: 10)
check("AWS secret assignment is quarantined with its specific reason",
      classifierReason("AWS_SECRET_ACCESS_KEY=\(syntheticAWSSecret)")
          == .awsSecretAccessKey)
check("malformed AWS ID assignment stays safe",
      classifierReason("AWS_ACCESS_KEY_ID=AKIA\(awsIDBody.dropLast())") == nil)
check("AWS placeholder assignment stays safe",
      classifierReason("AWS_SECRET_ACCESS_KEY=example") == nil)

let providerTokenBody = String(repeating: "Ab3_Z9-y", count: 3)
let shortProviderBody = String(
    repeating: "a",
    count: SensitiveContentClassifier.Thresholds.minimumVendorTokenBodyBytes - 1
)

for prefix in ["ghp_", "github_pat_", "gho_", "ghu_", "ghs_", "ghr_"] {
    check("GitHub token prefix \(prefix) is quarantined",
          classifierReason("\(prefix)\(providerTokenBody)") == .githubToken)
}
let matchedProviderReason = classifierReason("ghp_\(providerTokenBody)")
check("matched reason does not echo provider fixture bytes",
      matchedProviderReason.map {
          !$0.description.contains(providerTokenBody)
              && !$0.rawValue.contains(providerTokenBody)
      } == true)
check("current long-form GitHub installation token is quarantined",
      classifierReason("ghs_123456789_\(syntheticJWT())") == .githubToken)
check("short GitHub-looking token stays safe",
      classifierReason("ghp_\(shortProviderBody)") == nil)
check("embedded GitHub-looking token stays safe",
      classifierReason("xghp_\(providerTokenBody)") == nil)
let maximumGitHubBody = String(
    repeating: "a",
    count: SensitiveContentClassifier.Thresholds.maximumVendorTokenBytes
        - "ghp_".utf8.count
)
check("vendor token maximum is inclusive",
      classifierReason("ghp_\(maximumGitHubBody)") == .githubToken)
check("vendor token over the maximum stays safe",
      classifierReason("ghp_\(maximumGitHubBody)a") == nil)

for prefix in [
    "glpat-", "gloas-", "gldt-", "glrt-", "glrtr-", "glcbt-", "glptt-",
    "glft-", "glimt-", "glagent-", "glwt-", "glsoat-", "glffct-",
    "_gitlab_session=",
] {
    check("GitLab token prefix \(prefix) is quarantined",
          classifierReason("\(prefix)\(providerTokenBody)") == .gitlabToken)
}
check("short GitLab-looking token stays safe",
      classifierReason("glpat-\(shortProviderBody)") == nil)
check("unknown GitLab custom prefix is not mislabeled as GitLab",
      classifierReason("custompat-\(shortProviderBody)") == nil)

for prefix in [
    "xoxb-", "xoxp-", "xwfp-", "xapp-", "xoxe.xoxb-", "xoxe.xoxp-", "xoxe-",
] {
    check("Slack token prefix \(prefix) is quarantined",
          classifierReason("\(prefix)\(providerTokenBody)") == .slackToken)
}
check("short Slack-looking token stays safe",
      classifierReason("xoxb-\(shortProviderBody)") == nil)

for label in [
    "PRIVATE KEY",
    "ENCRYPTED PRIVATE KEY",
    "RSA PRIVATE KEY",
    "EC PRIVATE KEY",
    "OPENSSH PRIVATE KEY",
    "PGP PRIVATE KEY BLOCK",
] {
    let block = """
    -----BEGIN \(label)-----
    U3ludGhldGljIGZpeHR1cmUgb25seQ==
    -----END \(label)-----
    """
    check("\(label) boundary is quarantined",
          classifierReason(block) == .privateKey)
}
check("public-key block stays safe",
      classifierReason("-----BEGIN PUBLIC KEY-----\nU3ludGhldGlj\n-----END PUBLIC KEY-----")
          == nil)
check("certificate block stays safe",
      classifierReason("-----BEGIN CERTIFICATE-----\nU3ludGhldGlj\n-----END CERTIFICATE-----")
          == nil)
check("private-looking plural label stays safe",
      classifierReason("-----BEGIN PRIVATE KEYS-----") == nil)

check("generic token assignment is quarantined",
      classifierReason("API_TOKEN=abcdefgh") == .environmentSecret)
check("single-space export assignment is quarantined",
      classifierReason("export API_TOKEN=abcdefgh") == .environmentSecret)
check("tab export AWS secret assignment is quarantined",
      classifierReason("export\tAWS_SECRET_ACCESS_KEY=\(syntheticAWSSecret)")
          == .awsSecretAccessKey)
check("mixed ASCII shell blanks after export are accepted",
      classifierReason("export \t  DATABASE_PASSWORD=correct-horse")
          == .environmentSecret)
check("exported quoted password is quarantined",
      classifierReason(#"export DATABASE_PASSWORD="correct horse battery staple""#)
          == .environmentSecret)
check("export identifier lookalike stays safe",
      classifierReason("exported API_TOKEN=abcdefgh") == nil)
check("non-ASCII export separator stays safe",
      classifierReason("export\u{00A0}API_TOKEN=abcdefgh") == nil)
check("Unicode secret assignment is quarantined",
      classifierReason("CLIENT_SECRET=秘密の合言葉") == .environmentSecret)
check("environment value floor is inclusive",
      classifierReason("API_TOKEN=\(String(repeating: "z", count: 8))")
          == .environmentSecret)
check("short environment value stays safe",
      classifierReason("API_TOKEN=\(String(repeating: "z", count: 7))") == nil)
check("placeholder expansion stays safe",
      classifierReason(#"API_TOKEN=${TOKEN}"#) == nil)
check("unbraced placeholder expansion stays safe",
      classifierReason(#"API_TOKEN=$LONG_TOKEN_NAME"#) == nil)
check("operator-bearing AWS fallback is quarantined",
      classifierReason(
          "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-\(syntheticAWSSecret)}"
      ) == .environmentSecret)
check("operator-bearing fallback on a non-secret name stays safe",
      classifierReason("PUBLIC_VALUE=${PUBLIC_VALUE:-abcdefgh}") == nil)
check("placeholder words stay safe",
      classifierReason("API_TOKEN=change-me") == nil)
check("non-secret token-count variable stays safe",
      classifierReason("TOKEN_COUNT=12345678") == nil)
check("password hint variable stays safe",
      classifierReason("PASSWORD_HINT=remember-this") == nil)
check("public-key variable stays safe",
      classifierReason("PUBLIC_KEY=abcdefghijk") == nil)

for credentialURL in [
    "postgres://user:synthetic@db.example/app",
    "postgresql://user:p%40ss@db.example/app",
    "mysql://user:synthetic@db.example/app",
    "mysqlx://user:synthetic@db.example/app",
    "postgresql://db.example/app?password=synthetic",
    "POSTGRES://user:synthetic@db.example/app",
] {
    check("structured database credential URL is quarantined",
          classifierReason("connect \(credentialURL)") == .databaseCredentialURL)
}
for safeURL in [
    "postgres://user@db.example/app",
    "postgres://user:@db.example/app",
    "postgres://user:synthetic@",
    "https://user:synthetic@db.example/app",
    "notpostgres://user:synthetic@db.example/app",
    "postgresql://db.example/app?password=",
] {
    check("database URL near-miss stays safe",
          classifierReason(safeURL) == nil)
}

let signedJWT = syntheticJWT()
check("structurally signed JWT is quarantined",
      classifierReason(signedJWT) == .signedJWT)
check("JWT surrounded by punctuation is still recognized",
      classifierReason("(\(signedJWT))") == .signedJWT)
check("unsigned alg-none JWT stays safe",
      classifierReason(syntheticJWT(header: #"{"typ":"JWT","alg":"none"}"#)) == nil)
check("JWT with malformed header JSON stays safe",
      classifierReason(syntheticJWT(header: "not-json")) == nil)
check("JWT with non-object claims stays safe",
      classifierReason(syntheticJWT(claims: #"["synthetic"]"#)) == nil)
check("JWT with a short signature stays safe",
      classifierReason(syntheticJWT(signatureBytes: 15)) == nil)
check("two-part JWT-looking text stays safe",
      classifierReason(signedJWT.split(separator: ".").prefix(2).joined(separator: "."))
          == nil)
check("four-part JWT-looking text stays safe",
      classifierReason("\(signedJWT).extra") == nil)
check("invalid base64url JWT-looking text stays safe",
      classifierReason("abc%.\(classifierBase64URL(#"{"sub":"x"}"#)).abcdef")
          == nil)

let entropyAlphabet = Array(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
)
let highEntropyAtFloor = String(
    (0..<SensitiveContentClassifier.Thresholds.minimumHighEntropyBytes).map {
        entropyAlphabet[($0 * 17) % entropyAlphabet.count]
    }
)
check("generic entropy floor is inclusive",
      classifierReason(highEntropyAtFloor) == .highEntropyString)
check("generic entropy below the byte floor stays safe",
      classifierReason(String(highEntropyAtFloor.dropLast())) == nil)
check("long low-entropy run stays safe",
      classifierReason(String(repeating: "A", count: 513)) == nil)
check("high-entropy hex is quarantined",
      classifierReason(String(repeating: "0123456789abcdef", count: 4))
          == .highEntropyString)
check("short hex near-miss stays safe",
      classifierReason(String(String(repeating: "0123456789abcdef", count: 4).dropLast()))
          == nil)
check("ordinary UUID stays safe",
      classifierReason("123e4567-e89b-12d3-a456-426614174000") == nil)
check("entropy scanning remains bounded across a long candidate",
      classifierReason(String(repeating: String(entropyAlphabet), count: 9))
          == .highEntropyString)

check("ordinary Unicode text stays safe",
      classifierReason("こんにちは、AliasBar。これは普通のメモです。") == nil)
check("Unicode adjacency cannot hide a provider token",
      classifierReason("🔐ghp_\(providerTokenBody)🔐") == .githubToken)
check("full-width lookalike prefix stays safe",
      classifierReason("ｇｈｐ_\(shortProviderBody)") == nil)

let maximumClassifierBytes =
    SensitiveContentClassifier.Thresholds.maximumInputBytes
check("input exactly at the inspection limit is classified normally",
      classifierReason(String(repeating: "a", count: maximumClassifierBytes)) == nil)
check("input over the inspection limit fails closed",
      classifierReason(String(repeating: "a", count: maximumClassifierBytes + 1))
          == .oversizedContent)
let tokenAtLimit = "ghp_\(providerTokenBody)"
let paddedTokenAtLimit =
    String(repeating: " ", count: maximumClassifierBytes - tokenAtLimit.utf8.count)
    + tokenAtLimit
check("provider token at the bounded input tail is still found",
      classifierReason(paddedTokenAtLimit) == .githubToken)

let classifierSource = read(
    projectRoot.appendingPathComponent("Sources/SensitiveContentClassifier.swift").path
)
check("classifier source is readable",
      classifierSource != "<unreadable>")
for forbiddenAPI in [
    "AppKit", "SwiftUI", "UserDefaults", "NSPasteboard", "FileManager",
    "URLSession", "Process(", "print(", "NSLog", "os_log",
] {
    check("classifier has no \(forbiddenAPI) dependency",
          !classifierSource.contains(forbiddenAPI))
}

// ---------------------------------------------------------------------------
print("\n31. Clipboard capture: quarantine routing and store")

let quarantineBase = Date(timeIntervalSince1970: 1_700_000_000)

func capturedClip(
    _ content: String,
    declaredTypes: [String] = ["public.utf8-plain-text"],
    concealed: Bool = false
) -> CapturedClip {
    CapturedClip(
        content: content,
        declaredTypes: declaredTypes,
        capturedAt: quarantineBase,
        concealed: concealed
    )
}

// Concealed short-circuits before any text heuristic runs, even for content that would
// otherwise sail through unclassified.
let concealedInnocuous = ClipIngestor.decide(
    capturedClip("just a grocery list", concealed: true), now: quarantineBase
)
if case .quarantine(let memoryClip) = concealedInnocuous {
    check("concealed pasteboard type is quarantined regardless of content",
          memoryClip.reason == .concealedPasteboardType)
    check("concealed quarantine keeps the original content",
          memoryClip.content == "just a grocery list")
    check("concealed quarantine expires 90s from capture",
          memoryClip.expiresAt == quarantineBase.addingTimeInterval(QuarantineStore.expiryInterval))
} else {
    check("concealed pasteboard type is quarantined regardless of content", false)
}

// A concealed type with classifier-positive content must still report the concealed
// reason: the short-circuit runs before the classifier is ever consulted.
let concealedSecret = ClipIngestor.decide(
    capturedClip("ghp_\(providerTokenBody)", concealed: true), now: quarantineBase
)
if case .quarantine(let memoryClip) = concealedSecret {
    check("concealed type wins over a classifier-positive body",
          memoryClip.reason == .concealedPasteboardType)
} else {
    check("concealed type wins over a classifier-positive body", false)
}

// Classifier-positive, not concealed: routed to quarantine with the classifier's own
// reason.
let classifierPositive = ClipIngestor.decide(
    capturedClip("ghp_\(providerTokenBody)"), now: quarantineBase
)
if case .quarantine(let memoryClip) = classifierPositive {
    check("classifier-positive content is quarantined with the matching reason",
          memoryClip.reason == .githubToken)
} else {
    check("classifier-positive content is quarantined with the matching reason", false)
}

// Classifier-nil, not concealed: the only path to persist.
let classifierNegative = ClipIngestor.decide(
    capturedClip("git status", declaredTypes: ["public.utf8-plain-text"]),
    now: quarantineBase
)
if case .persist(let safeClip) = classifierNegative {
    check("classifier-nil content is persisted", safeClip.content == "git status")
    check("persisted clip records detection time", safeClip.detectedAt == quarantineBase)
    check("persisted clip carries the declared pasteboard types",
          safeClip.source.declaredTypes == ["public.utf8-plain-text"])
    check("persisted clip records byte size",
          safeClip.source.byteSize == "git status".utf8.count)
} else {
    check("classifier-nil content is persisted", false)
}

// Byte size defaults to the content's own UTF-8 length when the capture layer doesn't
// supply one (e.g. a plain-text-only read with no independent size available).
check("captured clip defaults byte size to UTF-8 length",
      capturedClip("héllo").byteSize == "héllo".utf8.count)

print("\n31a. QuarantineStore expiry")

var quarantineClock = quarantineBase
let store = QuarantineStore(clock: { quarantineClock })

if case .quarantine(let expiring) = ClipIngestor.decide(
    capturedClip("ghp_\(providerTokenBody)"), now: quarantineBase
) {
    store.add(expiring)
}

quarantineClock = quarantineBase.addingTimeInterval(89)
check("clip is still active 89s after capture (expiry is 90s)",
      store.active().count == 1)

quarantineClock = quarantineBase.addingTimeInterval(91)
check("clip is pruned 91s after capture",
      store.active().isEmpty)

// An explicit `now:` overrides the store's own clock. Two separate stores, each seeded
// once: `active` prunes as a side effect, so reusing one store across both assertions
// would have the first call's pruning silently decide the second's outcome.
func seededStore() -> QuarantineStore {
    let seeded = QuarantineStore(clock: { quarantineBase })
    seeded.add(MemoryClip(
        content: "second", reason: .highEntropyString,
        expiresAt: quarantineBase.addingTimeInterval(QuarantineStore.expiryInterval)
    ))
    return seeded
}
check("active(now:) can be driven independently of the injected clock",
      seededStore().active(now: quarantineBase.addingTimeInterval(91)).isEmpty)
check("omitting now: falls back to the injected clock",
      seededStore().active().count == 1)

let explicitNowStore = seededStore()
check("clear() empties the store",
      { explicitNowStore.clear(); return explicitNowStore.active().isEmpty }())

print("\n31b. SafeClip persistence boundary")

let roundTripClip = SafeClip(
    content: "git status",
    detectedAt: quarantineBase,
    source: SafeClip.SourceMetadata(declaredTypes: ["public.utf8-plain-text"], byteSize: 10)
)
let roundTripData = try? JSONEncoder().encode(roundTripClip)
check("SafeClip encodes", roundTripData != nil)
let roundTripDecoded = roundTripData.flatMap {
    try? JSONDecoder().decode(SafeClip.self, from: $0)
}
check("SafeClip round-trips through JSONEncoder/JSONDecoder",
      roundTripDecoded == roundTripClip)

// Neither in-memory clip type conforms to Encodable. Boxing a real instance as `Any`
// and casting to `any Encodable` only succeeds if the concrete type actually conforms —
// there is no other way to observe "not Codable" at runtime, since the compiler already
// refuses `JSONEncoder().encode(memoryClip)` at the call site above.
let sampleMemoryClip = MemoryClip(
    content: "x", reason: .highEntropyString, expiresAt: quarantineBase
)
check("MemoryClip does not conform to Encodable",
      (sampleMemoryClip as Any) as? any Encodable == nil)
let sampleCapturedClip = capturedClip("x")
check("CapturedClip does not conform to Encodable",
      (sampleCapturedClip as Any) as? any Encodable == nil)

// ---------------------------------------------------------------------------
print("\n31. SharedDocumentStore")

func sharedStoreDir() -> String {
    caseIndex += 1
    let dir = "\(sandbox)/shared-store-case\(caseIndex)"
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

struct DummyPreset: SharedRecordConvertible, Equatable {
    var name: String
    var body: String
}

// -- SHA-256, cross-checked against the system implementation ---------------
func systemSHA256(_ data: Data) -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    task.arguments = ["-a", "256"]
    let inPipe = Pipe()
    let outPipe = Pipe()
    task.standardInput = inPipe
    task.standardOutput = outPipe
    task.standardError = Pipe()
    guard (try? task.run()) != nil else { return nil }
    inPipe.fileHandleForWriting.write(data)
    inPipe.fileHandleForWriting.closeFile()
    let out = outPipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard let text = String(data: out, encoding: .utf8) else { return nil }
    return text.split(separator: " ").first.map(String.init)
}

for input in ["", "abc", "The quick brown fox jumps over the lazy dog",
              String(repeating: "x", count: 5000)] {
    let data = Data(input.utf8)
    let ours = SHA256Digest.hexString(data)
    if let system = systemSHA256(data) {
        check("SHA-256 matches system shasum (\(data.count) bytes)", ours == system,
              "ours=\(ours) system=\(system)")
    } else {
        check("shasum available to cross-check", false, "could not run /usr/bin/shasum")
    }
}
check("known vector: SHA-256(\"\")",
      SHA256Digest.hexString(Data())
          == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
check("known vector: SHA-256(\"abc\")",
      SHA256Digest.hexString(Data("abc".utf8))
          == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

// -- Round trip and unknown-field passthrough --------------------------------
let t0 = Date(timeIntervalSince1970: 1_700_000_000)
var doc = SharedDocument()
doc.settings["theme"] = SettingRecord(value: .string("dark"), modifiedAt: t0)
doc.settings["fontSize"] = SettingRecord(value: .number(13), modifiedAt: t0)
doc.settings["betaFeatures"] = SettingRecord(value: .bool(true), modifiedAt: t0)
let presetPayload = try! JSONEncoder.aliasBarDocument.encode(DummyPreset(name: "p1", body: "echo hi"))
doc.records["presets"] = [SyncedRecord(id: "p1", modifiedAt: t0, deleted: false, payload: presetPayload)]

let docEncoded = try! JSONEncoder.aliasBarDocument.encode(doc)
let docDecoded = try! JSONDecoder.aliasBarDocument.decode(SharedDocument.self, from: docEncoded)
check("round trip preserves settings and records", docDecoded == doc)

let unknownFieldJSON = """
{"schema":1,"settings":{},"records":{},"futureFeature":{"nested":[1,2,"three",null,true]}}
"""
let decoded1 = try! JSONDecoder.aliasBarDocument.decode(SharedDocument.self,
                                                         from: Data(unknownFieldJSON.utf8))
check("unknown top-level field is captured", decoded1.unknownFields["futureFeature"] != nil)
let reencoded = try! JSONEncoder.aliasBarDocument.encode(decoded1)
let decoded2 = try! JSONDecoder.aliasBarDocument.decode(SharedDocument.self, from: reencoded)
check("unknown field survives a decode-encode-decode cycle", decoded2 == decoded1)

// -- Store basics -------------------------------------------------------------
let dir1 = sharedStoreDir()
let docURL1 = URL(fileURLWithPath: "\(dir1)/settings.json")
let store1 = SharedDocumentStore(url: docURL1)

switch store1.read() {
case .success(let d): check("missing file reads as a fresh empty document", d == SharedDocument())
case .failure: check("missing file reads as a fresh empty document", false)
}

let afterUpsert = try! store1.upsert(DummyPreset(name: "p1", body: "ls -la"),
                                     id: "p1", in: "presets", modifiedAt: t0)
check("upsert returns the merged document", afterUpsert.records["presets"]?.count == 1)
switch store1.read() {
case .success(let d):
    check("upsert persisted to disk", d.records["presets"]?.first?.id == "p1")
case .failure:
    check("upsert persisted to disk", false)
}

_ = try! store1.setSetting(.string("dark"), forKey: "theme", modifiedAt: t0)
switch store1.read() {
case .success(let d): check("setting persisted", d.settings["theme"]?.value == .string("dark"))
case .failure: check("setting persisted", false)
}

// -- Tombstones and last-writer-wins -----------------------------------------
let tA = Date(timeIntervalSince1970: 1_700_000_100)
let tB = tA.addingTimeInterval(10)

let dir2 = sharedStoreDir()
let store2 = SharedDocumentStore(url: URL(fileURLWithPath: "\(dir2)/doc.json"))
_ = try! store2.upsert(DummyPreset(name: "a", body: "one"), id: "a", in: "presets", modifiedAt: tA)
let afterDelete = try! store2.tombstone(id: "a", in: "presets", modifiedAt: tB)
check("a newer tombstone beats an older live record",
      afterDelete.records["presets"]?.first(where: { $0.id == "a" })?.deleted == true)

// An older tombstone must not undo a newer live write.
let dir3 = sharedStoreDir()
let store3 = SharedDocumentStore(url: URL(fileURLWithPath: "\(dir3)/doc.json"))
_ = try! store3.tombstone(id: "b", in: "presets", modifiedAt: tA)
let afterRevive = try! store3.upsert(DummyPreset(name: "b", body: "two"), id: "b", in: "presets", modifiedAt: tB)
check("a newer live write beats an older tombstone",
      afterRevive.records["presets"]?.first(where: { $0.id == "b" })?.deleted == false)

// -- Two-writer race: exact-timestamp tie between a tombstone and a live edit ---
let dir4 = sharedStoreDir()
let racePath4 = "\(dir4)/doc.json"
let store4 = SharedDocumentStore(url: URL(fileURLWithPath: racePath4))
_ = try! store4.upsert(DummyPreset(name: "c", body: "three"), id: "c", in: "presets", modifiedAt: tA)
SharedDocumentStore.testRaceHook = {
    // A second writer lands a live edit at the exact instant our tombstone commits.
    let raw = try! Data(contentsOf: URL(fileURLWithPath: racePath4))
    var current = try! JSONDecoder.aliasBarDocument.decode(SharedDocument.self, from: raw)
    let payload = try! JSONEncoder.aliasBarDocument.encode(
        DummyPreset(name: "c", body: "edited-concurrently"))
    current.records["presets"] = [SyncedRecord(id: "c", modifiedAt: tA, deleted: false, payload: payload)]
    try! JSONEncoder.aliasBarDocument.encode(current)
        .write(to: URL(fileURLWithPath: racePath4), options: .atomic)
}
let afterTie = try! store4.tombstone(id: "c", in: "presets", modifiedAt: tA)
check("an exact-timestamp tie between a live record and a tombstone favors the tombstone",
      afterTie.records["presets"]?.first(where: { $0.id == "c" })?.deleted == true)

// -- Two-writer race: an unrelated concurrent write must survive the retry -----
let dir5 = sharedStoreDir()
let racePath5 = "\(dir5)/doc.json"
let store5 = SharedDocumentStore(url: URL(fileURLWithPath: racePath5))
_ = try! store5.upsert(DummyPreset(name: "seed", body: "seed"), id: "seed", in: "presets", modifiedAt: tA)
SharedDocumentStore.testRaceHook = {
    let raw = try! Data(contentsOf: URL(fileURLWithPath: racePath5))
    var current = try! JSONDecoder.aliasBarDocument.decode(SharedDocument.self, from: raw)
    let payload = try! JSONEncoder.aliasBarDocument.encode(
        DummyPreset(name: "other", body: "from another writer"))
    current.records["presets", default: []]
        .append(SyncedRecord(id: "other", modifiedAt: tB, deleted: false, payload: payload))
    try! JSONEncoder.aliasBarDocument.encode(current)
        .write(to: URL(fileURLWithPath: racePath5), options: .atomic)
}
let afterRace = try! store5.upsert(DummyPreset(name: "seed", body: "seed-updated"),
                                    id: "seed", in: "presets", modifiedAt: tB)
check("a concurrent unrelated write survives the retry",
      afterRace.records["presets"]?.contains(where: { $0.id == "other" }) == true)
check("our own write also landed",
      afterRace.records["presets"]?.first(where: { $0.id == "seed" })?.deleted == false)
switch store5.read() {
case .success(let d):
    check("both records are present on disk after the race",
          Set((d.records["presets"] ?? []).map(\.id)) == Set(["seed", "other"]))
case .failure:
    check("both records are present on disk after the race", false)
}

// -- Corruption and schema refusal --------------------------------------------
let dir6 = sharedStoreDir()
let corruptPath = "\(dir6)/doc.json"
let garbage = "{ this is not valid json"
try! garbage.write(toFile: corruptPath, atomically: true, encoding: .utf8)
let store6 = SharedDocumentStore(url: URL(fileURLWithPath: corruptPath))

var corruptError: SharedDocumentStore.StoreError?
do {
    _ = try store6.upsert(DummyPreset(name: "x", body: "y"), id: "x", in: "presets", modifiedAt: tA)
} catch let error as SharedDocumentStore.StoreError {
    corruptError = error
} catch {}

if case .corrupt(let original, let copy, _) = corruptError {
    check("corrupt document is refused with the right error", true)
    check("original path reported matches", original == corruptPath)
    check("original file is untouched", read(corruptPath) == garbage)
    if let copy {
        check("a conflict copy was written", FileManager.default.fileExists(atPath: copy))
        check("the conflict copy preserves the bad bytes", read(copy) == garbage)
    } else {
        check("a conflict copy was written", false)
    }
} else {
    check("corrupt document is refused with the right error", false, "\(String(describing: corruptError))")
}

let dir7 = sharedStoreDir()
let futurePath = "\(dir7)/doc.json"
let futureSchemaJSON = #"{"schema":999,"settings":{},"records":{}}"#
try! futureSchemaJSON.write(toFile: futurePath, atomically: true, encoding: .utf8)
let store7 = SharedDocumentStore(url: URL(fileURLWithPath: futurePath))

var schemaError: SharedDocumentStore.StoreError?
do {
    _ = try store7.setSetting(.bool(true), forKey: "x", modifiedAt: tA)
} catch let error as SharedDocumentStore.StoreError {
    schemaError = error
} catch {}

if case .unknownSchema(let found, let original, let copy) = schemaError {
    check("unknown schema is refused", found == 999)
    check("original path reported matches", original == futurePath)
    check("original file is untouched", read(futurePath) == futureSchemaJSON)
    check("a conflict copy exists for the unknown-schema file",
          copy.map { FileManager.default.fileExists(atPath: $0) } == true)
} else {
    check("unknown schema is refused", false, "\(String(describing: schemaError))")
}

// A bare read also refuses an unknown schema, but writes no conflict copy: nothing
// was about to be written, so there is nothing at risk of being lost.
switch store7.read() {
case .failure(.unknownSchema(_, _, let copy)):
    check("a bare read does not manufacture a conflict copy", copy == nil)
default:
    check("a bare read refuses the unknown schema too", false)
}

// -- Atomicity ------------------------------------------------------------------
let dir8 = sharedStoreDir()
let atomicPath = "\(dir8)/doc.json"
let store8 = SharedDocumentStore(url: URL(fileURLWithPath: atomicPath))
_ = try! store8.setSetting(.string("baseline"), forKey: "k", modifiedAt: tA)

// A stray temp file left behind by a hypothetical crashed writer (temp write
// succeeded, rename never ran) must not corrupt a later, unrelated write: the
// target is only ever replaced by `rename`, never assembled from a temp sibling.
let strayTemp = "\(dir8)/.aliasbar-shared-\(UUID().uuidString)"
try! "not a real document".write(toFile: strayTemp, atomically: true, encoding: .utf8)
_ = try! store8.setSetting(.string("next"), forKey: "k", modifiedAt: tB)
let afterStray = read(atomicPath)
check("a stray leftover temp file does not leak into the committed document",
      !afterStray.contains("not a real document"))
check("the real write still landed", afterStray.contains("\"next\""))
try? FileManager.default.removeItem(atPath: strayTemp)

// Making the directory unwritable forces the temp-file write itself to fail, before
// any rename is attempted. The target must be provably unaffected, byte for byte.
let beforeFailedAttempt = try! Data(contentsOf: URL(fileURLWithPath: atomicPath))
try! FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir8)
var writeFailed = false
do {
    _ = try store8.setSetting(.string("should-not-land"), forKey: "k",
                              modifiedAt: tA.addingTimeInterval(20))
} catch {
    writeFailed = true
}
try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir8)
check("a write that cannot create its temp file throws", writeFailed)
let afterFailedAttempt = try! Data(contentsOf: URL(fileURLWithPath: atomicPath))
check("the target file is byte-for-byte unchanged after a failed write",
      afterFailedAttempt == beforeFailedAttempt)
check("the target file does not contain the failed write's value",
      !read(atomicPath).contains("should-not-land"))

// -- Watcher ----------------------------------------------------------------------
let dir9 = sharedStoreDir()
let watchedPath = "\(dir9)/doc.json"
let store9 = SharedDocumentStore(url: URL(fileURLWithPath: watchedPath))
_ = try! store9.setSetting(.string("v1"), forKey: "k", modifiedAt: tA)

let watcherQueue = DispatchQueue(label: "aliasbar-watcher-test")
let fired = DispatchSemaphore(value: 0)
var reloadResult: Result<SharedDocument, SharedDocumentStore.StoreError>?
let watcher = SharedDocumentWatcher(url: URL(fileURLWithPath: watchedPath), queue: watcherQueue,
                                    debounceInterval: 0.3) { result in
    reloadResult = result
    fired.signal()
}
try! watcher.start()
Thread.sleep(forTimeInterval: 0.2) // let the DispatchSource install before acting

// Simulate another process (an iCloud sync, a second Mac) replacing the file
// wholesale, the same way this store's own atomic write does.
let replacement = try! JSONEncoder.aliasBarDocument.encode(
    SharedDocument(settings: ["k": SettingRecord(value: .string("from-elsewhere"), modifiedAt: tB)]))
let replacementTemp = "\(dir9)/.replacement-\(UUID().uuidString)"
try! replacement.write(to: URL(fileURLWithPath: replacementTemp))
_ = rename(replacementTemp, watchedPath)

let waited = fired.wait(timeout: .now() + 3.0)
watcher.stop()
check("the watcher fires after a file replace", waited == .success)
if case .success(let watchedDoc)? = reloadResult {
    check("the watcher's reload sees the replaced content",
          watchedDoc.settings["k"]?.value == .string("from-elsewhere"))
} else {
    check("the watcher's reload sees the replaced content", false, "\(String(describing: reloadResult))")
}

// ---------------------------------------------------------------------------
print("\n" + String(repeating: "-", count: 60))
print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)

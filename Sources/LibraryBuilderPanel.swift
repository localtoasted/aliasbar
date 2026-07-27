import AppKit
import SwiftUI

/// One compact entry point shared by onboarding and Settings. It copies instructions
/// for the chosen assistant, then validates a copied response into the existing Inbox.
/// Neither button writes to the prompt library or shell config.
struct LibraryBuilderPanel: View {
    @State private var kind: LibraryBuildKind = .prompt
    @State private var assistant: LibraryBuildAssistant = .chatGPT
    @State private var notice: String?
    @State private var noticeIsWarning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsRow("Build", hint: "Choose what you want suggestions for.") {
                ThemedSegments(selection: $kind,
                               options: LibraryBuildKind.allCases,
                               label: { $0.label })
            }
            SettingsRow("Use", hint: "AliasBar copies instructions for this assistant.") {
                ThemedSegments(selection: $assistant,
                               options: LibraryBuildAssistant.allCases,
                               label: { $0.label })
            }
            HStack(spacing: 8) {
                ThemedButton("Copy instructions") { copyInstructions() }
                ThemedButton("Add copied response to Inbox") { importResponse() }
                Spacer(minLength: 0)
            }
            if let notice {
                NoticeText(notice, tone: noticeIsWarning ? .warning : .info)
            } else {
                NoticeText("You approve each suggestion before AliasBar saves it.", tone: .info)
            }
        }
    }

    private func copyInstructions() {
        let prompts = PromptStore.scan(
            directory: URL(fileURLWithPath: AppPaths.promptsDirectory)
        ).prompts
        let entries = ZshrcParser.parse(path: AppPaths.rcPath).entries
        let instructions = LibraryBuilderPrompt.generate(
            kind: kind,
            assistant: assistant,
            prompts: prompts,
            shellEntries: entries)
        PasteboardBroker.write(transient: instructions)
        notice = "Instructions copied. Paste them into \(assistant.label)."
        noticeIsWarning = false
    }

    private func importResponse() {
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        do {
            let result = try PromptInbox.importText(
                copied,
                to: URL(fileURLWithPath: AppPaths.inboxDirectory))
            let noun = result.itemCount == 1 ? "suggestion" : "suggestions"
            notice = "Added \(result.itemCount) \(noun) to Inbox. Review them in Manage."
            noticeIsWarning = false
        } catch {
            notice = error.localizedDescription
            noticeIsWarning = true
        }
    }
}

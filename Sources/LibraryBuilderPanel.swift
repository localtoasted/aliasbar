import AppKit
import SwiftUI

/// One compact entry point shared by onboarding and Settings. It copies instructions
/// for the chosen assistant, then validates a copied response into the existing Inbox.
/// Neither button writes to the prompt library or shell config.
struct LibraryBuilderPanel: View {
    let promptsEnabled: Bool
    @State private var kind: LibraryBuildKind
    @State private var assistant: LibraryBuildAssistant
    @State private var notice: String?
    @State private var noticeIsWarning = false

    init(promptsEnabled: Bool) {
        self.promptsEnabled = promptsEnabled
        _kind = State(initialValue: promptsEnabled ? .prompt : .alias)
        _assistant = State(initialValue: promptsEnabled ? .chatGPT : .codex)
    }

    private var selectedKind: LibraryBuildKind {
        promptsEnabled ? kind : .alias
    }

    private var availableKinds: [LibraryBuildKind] {
        LibraryBuildKind.available(promptFeaturesEnabled: promptsEnabled)
    }

    private var availableAssistants: [LibraryBuildAssistant] {
        LibraryBuildAssistant.available(for: selectedKind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsRow("Build", hint: "Choose what you want suggestions for.") {
                Picker("Suggestion type", selection: Binding(
                    get: { selectedKind },
                    set: { kind = $0 }
                )) {
                    ForEach(availableKinds) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Suggestion type")
            }
            SettingsRow("Use", hint: "AliasBar copies instructions for this assistant.") {
                Picker("Assistant", selection: $assistant) {
                    ForEach(availableAssistants) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Assistant")
            }
            HStack(spacing: 8) {
                ThemedButton("Copy instructions") { copyInstructions() }
                ThemedButton("Import copied JSON") { importResponse() }
                Spacer(minLength: 0)
            }
            if let notice {
                NoticeText(notice, tone: noticeIsWarning ? .warning : .info)
            } else {
                NoticeText("You approve each suggestion before AliasBar saves it.", tone: .info)
            }
        }
        .onChange(of: kind) { newKind in
            if !assistant.supports(newKind) {
                assistant = LibraryBuildAssistant.available(for: newKind).first ?? .codex
            }
        }
        .onChange(of: promptsEnabled) { enabled in
            if !enabled { kind = .alias }
            if !assistant.supports(selectedKind) {
                assistant = LibraryBuildAssistant.available(for: selectedKind).first ?? .codex
            }
            notice = nil
        }
    }

    private func copyInstructions() {
        let prompts = PromptStore.scan(
            directory: URL(fileURLWithPath: AppPaths.promptsDirectory)
        ).prompts
        let entries = ZshrcParser.parse(path: AppPaths.rcPath).entries
        let instructions = LibraryBuilderPrompt.generate(
            kind: selectedKind,
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
                to: URL(fileURLWithPath: AppPaths.inboxDirectory),
                builderPolicy: PromptInbox.BuilderImportPolicy(
                    expectedKind: selectedKind.inboxKind,
                    expectedSource: assistant.schemaValue))
            let noun = result.itemCount == 1 ? "suggestion" : "suggestions"
            notice = "Added \(result.itemCount) \(noun). Open Manage, then Review."
            noticeIsWarning = false
        } catch {
            notice = error.localizedDescription
            noticeIsWarning = true
        }
    }
}

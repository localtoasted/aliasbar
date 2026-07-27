import SwiftUI

// MARK: - SlotFillState

/// The state one round of slot-filling needs: every unique slot name in the order it
/// should be asked for, the value typed so far for each, and which field currently
/// has focus.
///
/// Free of anything specific to prompt files — it knows only `[String]` slot names
/// and a `[String: String]` value map, the same shape `PromptSlotParser` already
/// works in. PRE-251's snippet holes are the same grammar over a different kind of
/// file, and reuse this exact type rather than growing a second one.
struct SlotFillState: Equatable {
    let slots: [String]
    var values: [String: String]
    var focusedIndex: Int

    init(slots: [String]) {
        self.slots = slots
        self.values = Dictionary(uniqueKeysWithValues: slots.map { ($0, "") })
        self.focusedIndex = 0
    }

    var focusedSlot: String? {
        slots.indices.contains(focusedIndex) ? slots[focusedIndex] : nil
    }

    func value(for slot: String) -> String {
        values[slot] ?? ""
    }

    mutating func setValue(_ value: String, for slot: String) {
        // Silently ignored for any name outside `slots` — there is no field for it
        // to belong to, and a stray write here should never grow `values` beyond
        // what `slots` promises.
        guard values.keys.contains(slot) else { return }
        values[slot] = value
    }

    /// Tab (`forward: true`) / Shift-Tab: moves focus to the next/previous slot,
    /// wrapping — the same reasoning FIND's own selection wraps rather than stopping
    /// at the ends.
    mutating func advance(forward: Bool) {
        guard !slots.isEmpty else { return }
        let delta = forward ? 1 : -1
        focusedIndex = ((focusedIndex + delta) % slots.count + slots.count) % slots.count
    }

    /// `body` rendered against whatever has been typed so far, via
    /// `PromptSlotParser.render` — never a second implementation of the same
    /// grammar. Only non-empty values are passed through: a field nobody has typed
    /// into yet stays exactly as written (`{{name}}`), matching `render`'s own rule
    /// for a slot with no supplied value at all, so the live preview shows precisely
    /// what confirming right now would deliver.
    func rendered(_ body: String) -> String {
        PromptSlotParser.render(body, values: values.filter { !$0.value.isEmpty })
    }
}

// MARK: - FillInSheet

/// A reusable slot-filling sheet: one text field per slot in `state.slots`, in
/// order, a live preview of `render(state)` underneath, Enter in any field confirms,
/// and Esc — handled one level up, at the same `AppState.handleKey` layer that
/// already owns Esc for the alias editor sheet — cancels back to whatever presented
/// this.
///
/// This view knows nothing about prompt files: no `Prompt`, no `Shortcut`, no
/// `PromptStore`. Everything prompt-specific — which shortcut this belongs to,
/// where the rendered text goes, when usage gets recorded — lives in the caller.
/// That is what lets PRE-251 hand this the exact same view with its own slots and
/// its own `render` closure instead of writing a second fill-in sheet.
struct FillInSheet: View {
    @Environment(\.theme) private var theme
    let title: String
    @Binding var state: SlotFillState
    let render: (SlotFillState) -> String
    var confirmLabel = "Paste"
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @FocusState private var focusedIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .bold, design: theme.bodyDesign))
                .foregroundStyle(theme.text)

            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(state.slots.enumerated()), id: \.offset) { index, slot in
                    field(slot, index: index)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("PREVIEW")
                    .font(.system(size: 9, weight: .bold))
                    .kerning(0.6)
                    .foregroundStyle(theme.faint)
                ScrollView {
                    Text(render(state))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.dim)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .padding(9)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
                .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius + 1)
                    .strokeBorder(theme.rule.opacity(0.5), lineWidth: 1))
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
        .background(theme.background)
        .onAppear { focusedIndex = state.slots.isEmpty ? nil : state.focusedIndex }
        // The field the user actually clicked (or Tab-moved to) is the source of
        // truth for `state.focusedIndex`, not the other way around — `onAppear`
        // above is the only place this view ever pushes focus onto the fields.
        .onChange(of: focusedIndex) { new in
            if let new { state.focusedIndex = new }
        }
    }

    private func field(_ slot: String, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(slot)
                .font(.system(size: 9, weight: .bold))
                .kerning(0.4)
                .foregroundStyle(theme.faint)
            TextField("", text: Binding(
                get: { state.value(for: slot) },
                set: { state.setValue($0, for: slot) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, design: theme.bodyDesign))
            .foregroundStyle(theme.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius + 1)
                .strokeBorder(theme.rule.opacity(0.5), lineWidth: 1))
            .focused($focusedIndex, equals: index)
            // Enter confirms from any field — a slotted prompt is usually one or two
            // short values, not a form someone reviews field by field before submitting.
            .onSubmit(onConfirm)
        }
    }
}

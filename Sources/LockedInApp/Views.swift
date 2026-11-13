import AppKit
import LockedInCore
import SwiftUI

struct MenuBarLabel: View {
    let model: StatusModel

    var body: some View {
        if model.isActive {
            Label(BlockDuration.clock(model.displayRemaining), systemImage: "lock.fill")
                .monospacedDigit()
        } else if !model.live {
            Image(systemName: "exclamationmark.lock")
        } else {
            Image(systemName: "lock.open")
        }
    }
}

struct PopoverView: View {
    let model: StatusModel
    let blocklist: BlocklistModel

    @AppStorage("maxBlockMinutes") private var maxBlockMinutes = Identifiers.defaultMaxBlockMinutes
    @AppStorage("expandSubdomains") private var expandSubdomains = true
    @AppStorage("lastDurationMinutes") private var durationMinutes = 60
    @State private var newSite = ""
    @State private var message: String?
    @State private var messageIsError = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private let presets: [(String, Int)] = [("30m", 30), ("1h", 60), ("2h", 120), ("4h", 240), ("8h", 480)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isActive, let report = model.report {
                activeSection(report)
            } else {
                idleSection
            }
            if !model.live {
                Label(
                    model.connectionError ?? "The LockedIn daemon is not answering.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(messageIsError ? .red : .secondary)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 330)
        .onAppear {
            model.isPopoverVisible = true
            model.refresh()
            blocklist.reload()
        }
        .onDisappear { model.isPopoverVisible = false }
    }

    // MARK: Idle

    private var idleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LockedIn").font(.headline)
            Text("Pick a length, then start. Nothing stops a block early.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                ForEach(presets, id: \.1) { preset in
                    Button(preset.0) { durationMinutes = min(preset.1, maxBlockMinutes) }
                        .buttonStyle(.bordered)
                        .tint(durationMinutes == preset.1 ? .accentColor : nil)
                }
            }
            HStack {
                Slider(
                    value: Binding(get: { Double(durationMinutes) }, set: { durationMinutes = Int($0) }),
                    in: 5...Double(max(5, maxBlockMinutes)), step: 5)
                Text(BlockDuration.words(Double(durationMinutes * 60)))
                    .monospacedDigit()
                    .frame(width: 64, alignment: .trailing)
            }

            HStack(alignment: .firstTextBaseline) {
                if blocklist.entries.isEmpty {
                    Text("Your blocklist is empty.").foregroundStyle(.secondary)
                } else {
                    Text(summary(blocklist.entries)).lineLimit(2)
                }
                Spacer()
                Button("Edit list…") {
                    openWindow(id: "blocklist"); NSApp.activate()
                }
                .buttonStyle(.link)
            }
            .font(.callout)

            Button {
                startBlock()
            } label: {
                Label(
                    model.busy ? "Starting…" : "Start \(BlockDuration.words(Double(durationMinutes * 60))) block",
                    systemImage: "lock.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(blocklist.entries.isEmpty || model.busy || !model.live)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func summary(_ entries: [String]) -> String {
        let shown = entries.prefix(4).joined(separator: ", ")
        return entries.count > 4 ? "\(shown) and \(entries.count - 4) more" : shown
    }

    private func startBlock() {
        message = nil
        let entries = blocklist.entries
        let seconds = durationMinutes * 60
        let expand = expandSubdomains
        Task {
            do {
                try await model.start(entries: entries, seconds: seconds, expand: expand)
            } catch {
                show(error.localizedDescription, isError: true)
            }
        }
    }

    // MARK: Active

    private func activeSection(_ report: StatusReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(BlockDuration.clock(model.displayRemaining))
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Spacer()
                if let end = report.expectedEnd {
                    Text("ends \(end, style: .time)").foregroundStyle(.secondary)
                }
            }
            Text(report.entries.joined(separator: "  "))
                .font(.callout)
                .lineLimit(3)
            Text("\(report.hostsNames.count) names blocked, \(report.ipCount) addresses in the firewall")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Add a site to this block", text: $newSite)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addSite)
                Button("Add", action: addSite).disabled(
                    newSite.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
            }
            HStack {
                Menu("Extend") {
                    ForEach([("15 minutes", 15), ("30 minutes", 30), ("1 hour", 60), ("2 hours", 120)], id: \.1) {
                        item in
                        Button(item.0) { extend(minutes: item.1) }
                    }
                }
                .frame(width: 110)
                Spacer()
                Text("There is no stop button.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func addSite() {
        let raw = newSite.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        do {
            _ = try BlockEntry.parse(raw)
        } catch {
            show(error.description, isError: true)
            return
        }
        Task {
            do {
                let added = try await model.add(entries: [raw])
                newSite = ""
                show(added.isEmpty ? "Already blocked." : "Added \(added.joined(separator: ", "))", isError: false)
            } catch {
                show(error.localizedDescription, isError: true)
            }
        }
    }

    private func extend(minutes: Int) {
        Task {
            do {
                try await model.extend(seconds: minutes * 60)
                show("Extended by \(BlockDuration.words(Double(minutes * 60))).", isError: false)
            } catch {
                show(error.localizedDescription, isError: true)
            }
        }
    }

    private func show(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Settings…") {
                openSettings(); NSApp.activate()
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .help("Quitting the app never affects a running block.")
        }
        .buttonStyle(.link)
        .font(.callout)
    }
}

struct BlocklistWindow: View {
    let blocklist: BlocklistModel
    @State private var newEntry = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(blocklist.entries, id: \.self) { entry in
                    HStack {
                        Text(entry)
                        Spacer()
                        Button {
                            blocklist.remove(entry)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove from the saved list (a running block keeps it)")
                    }
                }
                if blocklist.entries.isEmpty {
                    Text("No sites yet. Add one below, for example youtube.com.")
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("youtube.com, example.com:8080, ~reddit.com, 203.0.113.0/24", text: $newEntry)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Add", action: add).disabled(newEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Text("Prefix a site with ~ to block it by name only. Saved to \(blocklist.store.path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if blocklist.importedCount > 0 {
                    Text("Imported \(blocklist.importedCount) site(s) from SelfControl's old preferences.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
        .frame(minWidth: 420, minHeight: 360)
        .onAppear { blocklist.reload() }
    }

    private func add() {
        error = nil
        do {
            try blocklist.add(newEntry)
            newEntry = ""
        } catch let parseError as EntryError {
            error = parseError.description
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @AppStorage("maxBlockMinutes") private var maxBlockMinutes = Identifiers.defaultMaxBlockMinutes
    @AppStorage("expandSubdomains") private var expandSubdomains = true
    @AppStorage("playEndSound") private var playEndSound = true

    var body: some View {
        // Grouped puts each label on the left of its own row and wraps it. The default (columns) style
        // right-aligns labels into a column that overflowed the window and clipped the text.
        Form {
            Section {
                Stepper(value: $maxBlockMinutes, in: 30...(Identifiers.maxBlockSeconds / 60), step: 30) {
                    Text("Longest block the slider offers: \(BlockDuration.words(Double(maxBlockMinutes * 60)))")
                }
                // verbatim: a localized string key autolinks "www." as a URL.
                Toggle(isOn: $expandSubdomains) { Text(verbatim: "Also block www. and m. variants and known aliases") }
                Toggle("Play a sound when a block ends", isOn: $playEndSound)
            } footer: {
                Text(
                    "Blocks are enforced by a root daemon that keeps running after this app quits, after a restart, and after the clock is changed."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}

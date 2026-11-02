import CompanionCore
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        TabView(selection: $viewModel.selectedTab) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                page(for: tab)
                    .tabItem { Text(tab.title) }
                    .tag(tab)
            }
        }
        .padding(12)
        .frame(width: 560, height: 480)
    }

    @ViewBuilder private func page(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralPage(viewModel: viewModel)
        case .models: ModelsPage(viewModel: viewModel)
        case .privacy: PrivacyPage(viewModel: viewModel)
        case .browserExtension: BrowserExtensionPage(viewModel: viewModel)
        case .permissions: PermissionsPage(viewModel: viewModel)
        }
    }
}

private struct GeneralPage: View {
    let viewModel: SettingsViewModel

    var body: some View {
        Form {
            Toggle("Show orb", isOn: Binding(get: { viewModel.settings.orbEnabled }, set: { viewModel.setOrbEnabled($0) }))
            KeyboardShortcuts.Recorder("Summon:", name: .summon)
            KeyboardShortcuts.Recorder("Region capture:", name: .regionCapture)
            Text("⌥Space is also ChatGPT's default shortcut. If both apps use it, change one here.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

private struct ModelsPage: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var providerID = ModelRef.anthropicProviderID
    @State private var modelID = ""
    @State private var displayName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                keys
                models
                defaults
            }
            .padding()
        }
    }

    private var keys: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Anthropic API key") {
                SecureField("", text: $viewModel.anthropicKeyDraft).onSubmit { viewModel.commitAnthropicKey() }
            }
            LabeledContent("OpenAI-compatible base URL") {
                TextField("", text: $viewModel.baseURLDraft).onSubmit { viewModel.commitBaseURL() }
            }
            if let error = viewModel.baseURLError { Text(error).font(.caption).foregroundStyle(.red) }
            LabeledContent("OpenAI-compatible API key") {
                SecureField("", text: $viewModel.openAIKeyDraft).onSubmit { viewModel.commitOpenAIKey() }
            }
            if let error = viewModel.keyError { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Models (Tab cycles in this order)").font(.headline)
            ForEach(viewModel.settings.modelCycle, id: \.self) { model in
                HStack {
                    Text(model.displayName)
                    Text(model.modelID).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove") { viewModel.removeModel(model) }
                        .disabled(viewModel.settings.modelCycle.count <= 1)
                }
            }
            HStack {
                Picker("", selection: $providerID) {
                    Text("Anthropic").tag(ModelRef.anthropicProviderID)
                    Text("OpenAI-compatible").tag(ModelRef.openAICompatibleProviderID)
                }
                .labelsHidden()
                .fixedSize()
                TextField("Model ID", text: $modelID)
                TextField("Display name", text: $displayName)
                Button("Add") {
                    if viewModel.addModel(providerID: providerID, modelID: modelID, displayName: displayName) {
                        modelID = ""
                        displayName = ""
                    }
                }
            }
        }
    }

    private var defaults: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Default model by context").font(.headline)
            ForEach(ContextKind.allCases, id: \.self) { kind in
                Picker(SettingsViewModel.label(for: kind), selection: Binding(
                    get: { viewModel.settings.routing.model(for: kind) },
                    set: { viewModel.setDefault($0, for: kind) })) {
                    ForEach(viewModel.settings.modelCycle, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
        }
    }
}

private struct PrivacyPage: View {
    let viewModel: SettingsViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            EditableList(title: "Apps (bundle IDs)", items: viewModel.settings.blocklist.bundleIDs,
                         add: viewModel.addBlockedApp, remove: viewModel.removeBlockedApp)
            EditableList(title: "Sites (domains)", items: viewModel.settings.blocklist.domains,
                         add: viewModel.addBlockedDomain, remove: viewModel.removeBlockedDomain)
        }
        .padding()
    }
}

private struct EditableList: View {
    let title: String
    let items: [String]
    let add: (String) -> Void
    let remove: (String) -> Void
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            List(items, id: \.self) { item in
                HStack {
                    Text(item).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Remove") { remove(item) }.buttonStyle(.link)
                }
            }
            HStack {
                TextField("Add", text: $draft).onSubmit(commit)
                Button("Add", action: commit)
            }
        }
    }

    private func commit() {
        add(draft)
        draft = ""
    }
}

private struct BrowserExtensionPage: View {
    let viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(viewModel.pairingToken)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            HStack {
                Button("Copy") { viewModel.copyToken() }
                Button("Regenerate") { viewModel.regenerateToken() }
            }
            Text("Paste this code into the Companion Bridge extension's options page.")
                .foregroundStyle(.secondary)
            Text(SettingsViewModel.bridgeStatusText(viewModel.bridgeStatus))
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PermissionsPage: View {
    let viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Screen Recording", granted: viewModel.permissionStatus.screenRecording, kind: .screenRecording)
            row("Accessibility", granted: viewModel.permissionStatus.accessibility, kind: .accessibility)
            Spacer()
        }
        .padding()
    }

    private func row(_ title: String, granted: Bool, kind: PermissionKind) -> some View {
        HStack {
            Text(title)
            Text(granted ? "Granted" : "Not granted").foregroundStyle(granted ? .green : .orange)
            Spacer()
            Button("Open System Settings") { viewModel.openPermission(kind) }
        }
    }
}

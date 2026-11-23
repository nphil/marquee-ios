import LumaRemoteCore
import LumaRemoteKit
import MarqueeCore
import SwiftUI
import UIKit

/// A page pushed over the panel's face. The panel's `RemoteStage.path` holds them, so the TV's own events (a text
/// field opening, an invitation to pair) can open one from outside the view tree.
enum RemotePage: Hashable {
    case tvs, pairing, more, keyboard, settings, diagnostics
    case list(RemoteList)
}

/// One of the TV's lists.
enum RemoteList: Hashable {
    case apps, channels, cameras

    var kind: ListKind {
        switch self {
        case .apps: .apps
        case .channels: .channels
        case .cameras: .cameras
        }
    }

    var title: String {
        switch self {
        case .apps: "Apps"
        case .channels: "Channels"
        case .cameras: "Cameras"
        }
    }

    /// What choosing an item does on the TV.
    func action(_ id: ItemID) -> TVAction {
        switch self {
        case .apps: .launch(app: id)
        case .channels: .tune(channel: id)
        case .cameras: .camera(id)
        }
    }
}

extension RemoteModel {
    /// The connection in a few words, for the header and the TV list.
    var panelStatus: String {
        switch connection {
        case .none: "No TV chosen"
        case .connecting: "Connecting"
        case .connected: state.power == .standby ? "Standby" : "Connected"
        case .offline: "Off or out of reach"
        case .incompatible: "Needs an update"
        case .unpaired: "Needs pairing"
        }
    }

    /// The colour of the dot beside `panelStatus`.
    func panelStatusColour(_ theme: Theme) -> Color {
        switch connection {
        case .none, .offline: theme.ink3
        case .incompatible, .unpaired: theme.danger
        case .connecting: theme.warning
        case .connected: state.power == .standby ? theme.warning : theme.positive
        }
    }
}

/// A page over the panel's face, under the system's inline navigation bar, with a way to close the remote from
/// any depth.
struct RemotePageView: View {
    let page: RemotePage

    @Environment(AppSession.self) private var session
    @Environment(RemoteStage.self) private var stage
    @Environment(RemoteModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        content
            .background(theme.remotePanel.ignoresSafeArea())
            // The panel is already fitted above the keyboard, so the page must not move again.
            .ignoresSafeArea(.keyboard)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        session.remote.isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close remote")
                    .accessibilityIdentifier("remote.close")
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .tvs: RemoteTVList()
        case .pairing: PairingView(model: model) { stage.path = [] }
        case .more: RemoteMore()
        case .keyboard: RemoteKeyboardPage()
        case .settings: RemoteSettingsView(model: model)
        case .diagnostics: DiagnosticsView(model: model)
        case .list(let list): RemoteItemList(list: list)
        }
    }
}

// MARK: TVs

/// The paired TVs: choose the one the remote controls, forget one, or pair another.
private struct RemoteTVList: View {
    @Environment(RemoteStage.self) private var stage
    @Environment(RemoteModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var forgetting: PairedTV?

    var body: some View {
        List {
            if !model.tvs.isEmpty {
                Section("Paired TVs") {
                    ForEach(model.tvs) { tv in
                        Button {
                            model.select(tv)
                            stage.path = []
                        } label: {
                            row(tv)
                        }
                        .swipeActions {
                            Button("Forget", systemImage: "trash") { forgetting = tv }
                                .tint(theme.danger)
                        }
                        .contextMenu {
                            Button("Forget", systemImage: "trash", role: .destructive) { forgetting = tv }
                        }
                        .accessibilityAction(named: Text("Forget")) { forgetting = tv }
                        .listRowBackground(theme.glass)
                    }
                }
            }
            Section {
                NavigationLink(value: RemotePage.pairing) {
                    Label("Pair a TV", systemImage: "plus")
                        .foregroundStyle(theme.accentText)
                }
                .accessibilityIdentifier("tvs.pair")
                .listRowBackground(theme.glass)
            }
        }
        .themedList(theme, onCanvas: false)
        .navigationTitle("TVs")
        .confirmationDialog(
            forgetting.map { "Forget \($0.name)?" } ?? "",
            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
            titleVisibility: .visible,
            presenting: forgetting
        ) { tv in
            Button("Forget", role: .destructive) { model.forget(tv) }
        } message: { _ in
            Text("This phone stops controlling it. The TV keeps listing the phone until it's removed there, in Settings › Remote & pointer › Phone remote.")
        }
    }

    private func row(_ tv: PairedTV) -> some View {
        let current = model.current?.id == tv.id
        return HStack(spacing: Space.s3) {
            Image(systemName: "tv")
                .font(.system(size: Space.s5, weight: .semibold))
                .foregroundStyle(theme.ink2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s1 / 2) {
                Text(tv.name)
                    .textRole(.headline)
                    .foregroundStyle(theme.ink)
                Text(current ? model.panelStatus : tv.host)
                    .textRole(.caption)
                    .foregroundStyle(theme.ink2)
            }
            Spacer(minLength: 0)
            if current {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.accentText)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: Size.target)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

// MARK: More

/// Everything that is not on the remote's face, one tap away: the rest of the TV remote's keys, apps, LumaTV's own
/// actions while the TV offers them, and the remote's settings and diagnostics. What opens something on the TV
/// closes the page, so the pad is under the thumb again.
private struct RemoteMore: View {
    @Environment(RemoteStage.self) private var stage
    @Environment(RemoteModel.self) private var model

    private var ready: Bool { model.connection == .connected && model.state.power == .on }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s6) {
                Group {
                    MoreSection("Playback") {
                        KeyTile(.play, symbol: "play.fill", label: "Play")
                        KeyTile(.pause, symbol: "pause.fill", label: "Pause")
                        KeyTile(.stop, symbol: "stop.fill", label: "Stop")
                    }
                    MoreSection("TV") {
                        KeyTile(.info, symbol: "info.circle", label: "Info")
                        KeyTile(.more, symbol: "ellipsis.circle", label: "More actions")
                        KeyTile(.exit, symbol: "rectangle.portrait.and.arrow.right", label: "Exit")
                        KeyTile(.input, symbol: "cable.connector.horizontal", label: "Input")
                        KeyTile(.list, symbol: "list.bullet", label: "Channel list")
                        ActionTile(symbol: "gearshape.2", label: "All settings") {
                            if model.state.allows(.settings(page: nil)) {
                                await run(.settings(page: nil))
                            } else if model.send(.key(.menu, .hold)) {
                                stage.path = []
                            }
                        }
                    }
                    MoreSection("Colour keys") {
                        ColourKey(key: .red, colour: .red, label: "Red")
                        ColourKey(key: .green, colour: .green, label: "Green")
                        ColourKey(key: .yellow, colour: .yellow, label: "Yellow")
                        ColourKey(key: .blue, colour: .blue, label: "Blue")
                    }
                    MoreSection("Apps") {
                        KeyTile(.netflix, symbol: "n.square", label: "Netflix")
                        KeyTile(.amazon, symbol: "a.square", label: "Prime Video")
                        if model.state.allows(.launch(app: .string(""))) {
                            ListTile(symbol: "square.grid.2x2", label: "All apps", page: .list(.apps))
                        }
                    }
                    if hasLumaTVActions {
                        lumaTV
                    }
                }
                .disabled(!ready)
                MoreSection("Remote") {
                    ListTile(symbol: "iphone", label: "Settings", page: .settings)
                    ListTile(symbol: "stethoscope", label: "Diagnostics", page: .diagnostics)
                }
            }
            .padding(Space.s4)
        }
        .navigationTitle("More")
    }

    private static let lumaTVActions: [TVAction] = [
        .quickSettings, .settings(page: nil), .notifications, .inputPicker, .pictureOff, .cameras, .closeCamera,
        .camera(.string("")), .tune(channel: .string("")), .volume(level: 0),
    ]

    private var hasLumaTVActions: Bool {
        Self.lumaTVActions.contains(where: model.state.allows)
    }

    /// LumaTV's own actions. Home, the guide and power are keys on the remote's face.
    private var lumaTV: some View {
        let state = model.state
        return MoreSection("LumaTV") {
            if state.allows(.quickSettings) {
                ActionTile(symbol: "slider.horizontal.3", label: "Quick Settings") { await run(.quickSettings) }
            }
            if state.allows(.settings(page: nil)) {
                ActionTile(symbol: "gearshape", label: "Settings") { await run(.settings(page: nil)) }
            }
            if state.allows(.notifications) {
                ActionTile(symbol: "bell", label: "Notifications") { await run(.notifications) }
            }
            if state.allows(.inputPicker) {
                ActionTile(symbol: "rectangle.on.rectangle", label: "Inputs") { await run(.inputPicker) }
            }
            if state.allows(.tune(channel: .string(""))) {
                ListTile(symbol: "list.number", label: "Channels", page: .list(.channels))
            }
            if state.allows(.cameras) {
                ActionTile(symbol: "video", label: "Cameras") { await run(.cameras) }
            }
            if state.allows(.camera(.string(""))) {
                ListTile(symbol: "list.bullet.rectangle", label: "One camera", page: .list(.cameras))
            }
            if state.allows(.closeCamera) {
                ActionTile(symbol: "video.slash", label: "Close camera") { await model.perform(.closeCamera) }
            }
            if state.allows(.pictureOff) {
                ActionTile(symbol: "eye.slash", label: "Picture off") { await model.perform(.pictureOff) }
            }
        } footer: {
            if state.allows(.volume(level: 0)) {
                ReceiverVolume()
            }
        }
    }

    /// Runs an action that opens something on the TV, and goes back to the face once the TV has done it.
    private func run(_ action: TVAction) async {
        if await model.perform(action) { stage.path = [] }
    }
}

/// A titled plate of tiles, with room below for a control that needs the full width.
private struct MoreSection<Tiles: View, Footer: View>: View {
    let title: String
    @ViewBuilder let tiles: Tiles
    @ViewBuilder let footer: Footer

    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .caption) private var tileWidth: CGFloat = 76

    init(_ title: String, @ViewBuilder tiles: () -> Tiles, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.tiles = tiles()
        self.footer = footer()
    }

    var body: some View {
        let plate = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(title)
                .textRole(.label)
                .foregroundStyle(theme.ink2)
                .padding(.leading, Space.s1)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: Space.s4) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: tileWidth), spacing: Space.s2, alignment: .top)], spacing: Space.s4) {
                    tiles
                }
                footer
            }
            .padding(Space.s4)
            .background(theme.glass, in: plate)
            .overlay(plate.strokeBorder(theme.edge, lineWidth: 1))
        }
    }
}

extension MoreSection where Footer == EmptyView {
    init(_ title: String, @ViewBuilder tiles: () -> Tiles) {
        self.init(title, tiles: tiles, footer: { EmptyView() })
    }
}

/// A key above its name. The name is for sighted people scanning the page; VoiceOver reads the key's own label.
private struct MoreTile<Key: View>: View {
    let label: String
    @ViewBuilder let key: Key

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: Space.s1) {
            key
                .frame(height: RemoteMetrics.key)
            Text(label)
                .textRole(.caption)
                .foregroundStyle(theme.ink2)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct KeyTile: View {
    let spec: RemoteKeySpec

    init(_ key: RemoteKey, symbol: String, label: String) {
        spec = RemoteKeySpec(key: key, symbol: symbol, label: label)
    }

    var body: some View {
        MoreTile(label: spec.label) { RemoteKeyButton(spec: spec) }
    }
}

private struct ActionTile: View {
    let symbol: String
    let label: String
    let action: () async -> Void

    @State private var running = false

    var body: some View {
        MoreTile(label: label) {
            RemoteActionKey(symbol: symbol, label: label) {
                guard !running else { return }
                running = true
                Task {
                    await action()
                    running = false
                }
            }
        }
    }
}

private struct ListTile: View {
    let symbol: String
    let label: String
    let page: RemotePage

    var body: some View {
        MoreTile(label: label) {
            NavigationLink(value: page) {
                Image(systemName: symbol)
            }
            .buttonStyle(RemoteKeyButtonStyle())
            .accessibilityLabel(Text(label))
        }
    }
}

/// The TV remote's red, green, yellow and blue keys keep their colours on every theme: they are the keys' own identity.
private struct ColourKey: View {
    let key: RemoteKey
    let colour: Color
    let label: String

    @Environment(RemoteModel.self) private var model
    @Environment(\.isEnabled) private var isEnabled
    @State private var pressed = false

    var body: some View {
        MoreTile(label: label) {
            Image(systemName: "circle.fill")
                .foregroundStyle(colour)
                .opacity(isEnabled ? 1 : RemoteSize.unavailable)
                .modifier(RemoteKeyCap(style: .raised, pressed: pressed))
                .modifier(RemoteKeyPress(key: key, pressed: $pressed))
                .remoteKeyAccessibility(label, symbol: "circle.fill") { model.tap(key) }
                .accessibilityIdentifier("remote.key.\(key.rawValue)")
        }
    }
}

// MARK: Lists and the receiver

/// One of the TV's lists; choosing an item runs its action and goes back to the face.
private struct RemoteItemList: View {
    let list: RemoteList

    @Environment(RemoteStage.self) private var stage
    @Environment(RemoteModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var items: [ListItem]?
    @State private var failed = false
    @State private var query = ""

    var body: some View {
        List {
            if let items {
                ForEach(filtered(items)) { item in
                    Button {
                        let target = list.action(item.id)
                        Task {
                            if await model.perform(target) { stage.path = [] }
                        }
                    } label: {
                        HStack(spacing: Space.s3) {
                            if let number = item.no {
                                Text(number)
                                    .monospacedDigit()
                                    .foregroundStyle(theme.ink2)
                            }
                            Text(item.label)
                                .foregroundStyle(theme.ink)
                        }
                        .frame(minHeight: Size.target)
                    }
                    .listRowBackground(theme.glass)
                }
            } else if failed {
                Text("Couldn't get the list from the TV.")
                    .foregroundStyle(theme.ink2)
                    .listRowBackground(theme.glass)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(theme.glass)
            }
        }
        .themedList(theme, onCanvas: false)
        .searchable(text: $query)
        .navigationTitle(list.title)
        .task {
            if let loaded = await model.list(list.kind) { items = loaded } else { failed = true }
        }
    }

    private func filtered(_ items: [ListItem]) -> [ListItem] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        return items.filter { $0.label.localizedCaseInsensitiveContains(query) || $0.no == query }
    }
}

/// The AV receiver's level, set when the finger lifts; the volume keys still step it.
private struct ReceiverVolume: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var level: Double = 0
    @State private var editing = false

    var body: some View {
        let volume = model.state.volume
        let maximum = max(volume?.max ?? 100, 1)
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack {
                Label("Receiver volume", systemImage: "hifispeaker")
                Spacer()
                Text(VolumeState.format(level))
                    .monospacedDigit()
                    .foregroundStyle(theme.ink2)
            }
            .textRole(.label)
            .foregroundStyle(theme.ink)
            Slider(value: $level, in: 0...maximum, step: 0.5) {
                Text("Receiver volume")
            } onEditingChanged: { editing in
                self.editing = editing
                if !editing {
                    let target = level
                    Task { await model.perform(.volume(level: target)) }
                }
            }
            .tint(theme.accent)
        }
        .onAppear { level = volume?.level ?? 0 }
        .onChange(of: volume?.level) { _, new in
            if !editing, let new { level = new }
        }
    }
}

// MARK: Keyboard

/// The keyboard bridge: a field whose text is mirrored into the TV's, so the phone's keyboard, dictation and
/// autofill type on the TV.
private struct RemoteKeyboardPage: View {
    @Environment(RemoteStage.self) private var stage
    @Environment(RemoteModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s2) {
                RemoteBridgeField(model: model, ime: model.state.ime, ink: UIColor(theme.ink), tint: UIColor(theme.accentText))
                    .frame(minHeight: Size.target)
                    .padding(.horizontal, Space.s3)
                    .background(theme.glassRaised, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                Button {
                    stage.showKeyboard(false, followingTV: false)
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                }
                .buttonStyle(.round)
                .accessibilityLabel("Hide keyboard")
                .accessibilityIdentifier("remote.keyboard.hide")
            }
            Text("What is typed here goes into the TV's text field. Return sends Enter.")
                .textRole(.caption)
                .foregroundStyle(theme.ink2)
            Spacer(minLength: 0)
        }
        .padding(Space.s4)
        .navigationTitle("Keyboard")
    }
}

/// A field whose committed text is mirrored into the TV's, as backspaces back to where it differs and then the
/// new text. Return sends Enter and starts afresh; a backspace in the empty field still deletes on the TV.
private struct RemoteBridgeField: UIViewRepresentable {
    let model: RemoteModel
    let ime: IMEState
    let ink: UIColor
    let tint: UIColor

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> RemoteBackspaceField {
        let field = RemoteBackspaceField()
        let coordinator = context.coordinator
        field.delegate = coordinator
        field.addTarget(coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.onEmptyBackspace = { coordinator.model.edit(.backspace(1)) }
        field.font = .preferredFont(forTextStyle: .body)
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.adjustsFontForContentSizeCategory = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.accessibilityLabel = "Text for the TV"
        field.accessibilityIdentifier = "remote.keyboard.field"
        Task { @MainActor in field.becomeFirstResponder() }
        return field
    }

    func updateUIView(_ field: RemoteBackspaceField, context: Context) {
        field.textColor = ink
        field.tintColor = tint
        context.coordinator.configure(field, for: ime)
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        let model: RemoteModel
        /// The field's text as the TV last heard it.
        private var sent = ""
        private var configured: IMEState?

        init(model: RemoteModel) {
            self.model = model
        }

        @objc func changed(_ field: UITextField) {
            // Text still being composed, such as a Japanese reading, goes over once it is chosen.
            guard field.markedTextRange == nil else { return }
            let text = field.text ?? ""
            model.type(from: sent, to: text)
            sent = text
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            guard field.markedTextRange == nil else { return true }
            model.edit(.enter)
            field.text = ""
            sent = ""
            return false
        }

        func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            guard let limit = configured?.max, limit > 0, let text = field.text, let range = Range(range, in: text) else { return true }
            return text.replacingCharacters(in: range, with: string).count <= limit
        }

        /// Keyboard type, Return key, capitals, corrections and secure entry, from the TV field's kind.
        func configure(_ field: UITextField, for ime: IMEState) {
            guard configured != ime else { return }
            configured = ime
            let purpose = ime.purposeKind
            field.keyboardType = switch purpose {
            case .digits, .number: .numbersAndPunctuation
            case .phone: .phonePad
            case .url: .URL
            case .email: .emailAddress
            default: .default
            }
            field.returnKeyType = switch ime.enterKind {
            case .done: .done
            case .go: .go
            case .send: .send
            case .search: .search
            case .next: .next
            default: .default
            }
            let literal = ime.sensitive || ime.hiddenText || [.url, .email, .password, .terminal].contains(purpose)
            field.autocapitalizationType = if ime.uppercase {
                .allCharacters
            } else if ime.titlecase || purpose == .name {
                .words
            } else if ime.lowercase || literal {
                .none
            } else {
                .sentences
            }
            field.autocorrectionType = literal ? .no : .default
            field.spellCheckingType = literal ? .no : .default
            field.isSecureTextEntry = ime.hiddenText
            field.textContentType = switch purpose {
            case .password: .password
            case .email: .emailAddress
            case .url: .URL
            default: nil
            }
            if field.isFirstResponder { field.reloadInputViews() }
        }
    }
}

final class RemoteBackspaceField: UITextField {
    var onEmptyBackspace: (() -> Void)?

    override func deleteBackward() {
        if (text ?? "").isEmpty { onEmptyBackspace?() }
        super.deleteBackward()
    }
}

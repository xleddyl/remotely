import SwiftUI
import UIKit

func keyWindowSafeAreaInsets() -> UIEdgeInsets {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first { $0.isKeyWindow }?.safeAreaInsets ?? .zero
}

enum ToolbarHaptics {
    static let selectionHaptics = UISelectionFeedbackGenerator()
    static let impactHaptics = UIImpactFeedbackGenerator(style: .rigid)
}

enum ToolbarMotion {
    static let expand = Animation.spring(response: 0.32, dampingFraction: 0.86)
}

extension View {

    @ViewBuilder
    func liquidGlass<S: InsettableShape>(in shape: S, tint: Color? = nil,
                                         interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
            } else {
                glassEffect(.regular.interactive(interactive), in: shape)
            }
        } else {
            background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if let tint { shape.fill(tint.opacity(0.85)) }
                }
            }
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
        }
    }

    @ViewBuilder
    func scrollClipDisabledIfNeeded() -> some View {
        if #available(iOS 17.0, *) {
            scrollClipDisabled()
        } else {
            self
        }
    }
}

struct ToolbarGlassRow<Content: View>: View {

    private let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                HStack(spacing: spacing) { content }
            }
        } else {
            HStack(spacing: spacing) { content }
        }
    }
}

final class InputController: ObservableObject {

    @Published private(set) var latched: WireModifiers = []
    @Published private(set) var softKeyboardVisible = false
    @Published var expanded = false

    weak var receiver: PhoneReceiver?

    var presentSoftKeyboard: (() -> Void)?
    var dismissSoftKeyboard: (() -> Void)?

    private var heldKeys: Set<String> = []

    var wireMods: Int { latched.rawValue }

    func isLatched(_ modifier: WireModifiers) -> Bool { latched.contains(modifier) }

    func toggleLatch(_ modifier: WireModifiers) {
        if latched.contains(modifier) {
            latched.remove(modifier)
        } else {
            latched.insert(modifier)
        }
    }

    func toggleSoftKeyboard() { setSoftKeyboardVisible(!softKeyboardVisible) }

    func setSoftKeyboardVisible(_ visible: Bool) {
        guard softKeyboardVisible != visible else { return }
        softKeyboardVisible = visible
        if visible { presentSoftKeyboard?() } else { dismissSoftKeyboard?() }
    }

    func reset() {
        for name in heldKeys {
            receiver?.sendKey(phase: "up", key: name, mods: latched.rawValue)
        }
        heldKeys.removeAll()
        latched = []
        setSoftKeyboardVisible(false)
    }

    func tapKey(_ name: String) {
        let mods = wireMods
        receiver?.sendKey(phase: "down", key: name, mods: mods)
        receiver?.sendKey(phase: "up", key: name, mods: mods)
    }

    func tapCombo(mods: WireModifiers, key: String) {
        guard !key.isEmpty else { return }
        let all = mods.union(latched).rawValue
        receiver?.sendKey(phase: "down", key: key, mods: all)
        receiver?.sendKey(phase: "up", key: key, mods: all)
    }

    func insertText(_ text: String) {
        let mods = latched
        guard !mods.subtracting([.shift, .capsLock]).isEmpty else {
            receiver?.sendText(text, mods: mods.rawValue)
            return
        }
        guard let name = WireKeyMap.name(forCharacter: text) else {
            receiver?.sendText(text, mods: mods.rawValue)
            return
        }
        if text.count == 1, let char = text.first, char.isUppercase {
            tapCombo(mods: [.shift], key: name)
        } else {
            tapKey(name)
        }
    }

    func handlePresses(_ presses: Set<UIPress>, down: Bool, allowText: Bool) -> Bool {
        guard receiver?.macSupportsKeyboardWire == true else { return false }
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            if WireKeyMap.isModifierKey(key) {
                handled = true
                continue
            }
            let mods = WireKeyMap.modifiers(from: key.modifierFlags).union(latched)
            let isChord = !mods.subtracting([.shift, .capsLock]).isEmpty
            guard let name = WireKeyMap.name(for: key) else { continue }
            if down {
                if !isChord, let text = WireKeyMap.typedText(for: key) {
                    guard allowText else { continue }
                    receiver?.sendText(text, mods: mods.rawValue)
                    handled = true
                    continue
                }
                heldKeys.insert(name)
                receiver?.sendKey(phase: "down", key: name, mods: mods.rawValue)
            } else {
                guard heldKeys.remove(name) != nil else { continue }
                receiver?.sendKey(phase: "up", key: name, mods: mods.rawValue)
            }
            handled = true
        }
        return handled
    }
}

struct PerfOverlayHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

final class DragVelocitySampler {

    private static let minimumSampleInterval: TimeInterval = 0.004
    private static let staleAfter: TimeInterval = 0.08
    private static let smoothing: CGFloat = 0.65

    private var lastTranslation = CGSize.zero
    private var lastTime: Date?
    private var smoothed = CGSize.zero

    func begin(translation: CGSize, at time: Date) {
        lastTranslation = translation
        lastTime = time
        smoothed = .zero
    }

    func record(translation: CGSize, at time: Date) {
        guard let previous = lastTime else {
            begin(translation: translation, at: time)
            return
        }
        let elapsed = time.timeIntervalSince(previous)
        guard elapsed >= Self.minimumSampleInterval else { return }
        let sample = CGSize(width: (translation.width - lastTranslation.width) / elapsed,
                            height: (translation.height - lastTranslation.height) / elapsed)
        smoothed = CGSize(
            width: sample.width * Self.smoothing + smoothed.width * (1 - Self.smoothing),
            height: sample.height * Self.smoothing + smoothed.height * (1 - Self.smoothing))
        lastTranslation = translation
        lastTime = time
    }

    func release(at time: Date) -> CGSize {
        defer { lastTime = nil }
        guard let previous = lastTime,
              time.timeIntervalSince(previous) <= Self.staleAfter else { return .zero }
        return smoothed
    }
}

final class ToolbarSettle {

    private static let stiffness: CGFloat = 320
    private static let damping: CGFloat = 29
    private static let restDistance: CGFloat = 0.5
    private static let restSpeed: CGFloat = 8

    private var link: CADisplayLink?
    private var position = CGSize.zero
    private var speed = CGSize.zero
    private var apply: ((CGSize) -> Void)?
    private var lastFrame: CFTimeInterval = 0

    func stop() {
        link?.invalidate()
        link = nil
        apply = nil
    }

    func start(from: CGSize, velocity: CGSize, apply: @escaping (CGSize) -> Void) {
        stop()
        guard !atRest(position: from, speed: velocity) else {
            apply(.zero)
            return
        }
        position = from
        speed = velocity
        self.apply = apply
        lastFrame = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func atRest(position: CGSize, speed: CGSize) -> Bool {
        hypot(position.width, position.height) < Self.restDistance
            && hypot(speed.width, speed.height) < Self.restSpeed
    }

    @objc private func step(_ link: CADisplayLink) {
        let elapsed = min(max(link.timestamp - lastFrame, 1.0 / 240), 1.0 / 30)
        lastFrame = link.timestamp
        let step = CGFloat(elapsed)
        speed.width += (-Self.stiffness * position.width - Self.damping * speed.width) * step
        speed.height += (-Self.stiffness * position.height - Self.damping * speed.height) * step
        position.width += speed.width * step
        position.height += speed.height * step
        guard !atRest(position: position, speed: speed) else {
            let finish = apply
            stop()
            finish?(.zero)
            return
        }
        apply?(position)
    }
}

enum ToolbarCorner: String, CaseIterable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var isTop: Bool { self == .topLeading || self == .topTrailing }
    var isLeading: Bool { self == .topLeading || self == .bottomLeading }

    var alignment: Alignment {
        switch self {
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }

    static func nearest(to point: CGPoint, in size: CGSize) -> ToolbarCorner {
        let leading = point.x < size.width / 2
        let top = point.y < size.height / 2
        if top { return leading ? .topLeading : .topTrailing }
        return leading ? .bottomLeading : .bottomTrailing
    }
}

struct InputToolbar: View {

    @ObservedObject var controller: InputController
    let supported: Bool
    let safeArea: EdgeInsets
    let keyboardHeight: CGFloat
    let bottomObstruction: CGFloat

    @AppStorage("inputToolbarCorner") private var dockedCorner = ToolbarCorner.topTrailing.rawValue
    @State private var dragOffset = CGSize.zero
    @State private var dragBase = CGSize.zero
    @State private var touching = false
    @State private var dragging = false
    @State private var windowInsets = UIEdgeInsets.zero
    @State private var velocitySampler = DragVelocitySampler()
    @State private var settle = ToolbarSettle()

    private static let handleDiameter: CGFloat = 44
    private static let dragSpace = "inputToolbarDragSpace"
    private static let dragSlop: CGFloat = 10
    private static let flickProjection: CGFloat = 0.5
    private static let chipDiameter: CGFloat = 38
    private static let chipAnimation = Animation.spring(response: 0.28, dampingFraction: 0.82)

    private static let modifierChips: [(WireModifiers, String, String)] = [
        (.command, "⌘", "Command"),
        (.option, "⌥", "Option"),
        (.control, "⌃", "Control"),
        (.shift, "⇧", "Shift"),
    ]

    private var corner: ToolbarCorner {
        ToolbarCorner(rawValue: dockedCorner) ?? .topTrailing
    }

    var body: some View {
        GeometryReader { proxy in
            let insets = dockInsets(for: corner)
            dockedRow(in: proxy.size)
                .padding(.top, corner.isTop ? insets.top : 0)
                .padding(.bottom, corner.isTop ? 0 : insets.bottom)
                .padding(.leading, insets.leading)
                .padding(.trailing, insets.trailing)
                .offset(dragOffset)
                .frame(width: proxy.size.width, height: proxy.size.height,
                       alignment: corner.alignment)
                .onChange(of: proxy.size) { _ in refreshWindowInsets() }
        }
        .coordinateSpace(name: Self.dragSpace)
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
        .onAppear { refreshWindowInsets() }
        .onDisappear { settle.stop() }
        .onChange(of: safeArea) { _ in refreshWindowInsets() }
        .onChange(of: keyboardHeight) { _ in refreshWindowInsets() }
    }

    private func refreshWindowInsets() {
        DispatchQueue.main.async { windowInsets = keyWindowSafeAreaInsets() }
    }

    private func dockInsets(for corner: ToolbarCorner) -> EdgeInsets {
        let window = windowInsets
        let bottomKeyboard = corner.isTop ? 0 : keyboardHeight
        let bottomOverlay = corner.isTop ? 0 : bottomObstruction
        return EdgeInsets(
            top: max(safeArea.top, window.top, 10) + 8,
            leading: max(safeArea.leading, window.left, 12),
            bottom: max(safeArea.bottom, window.bottom, 10) + 8 + bottomKeyboard + bottomOverlay,
            trailing: max(safeArea.trailing, window.right, 12))
    }

    private func dockedRow(in size: CGSize) -> some View {
        HStack(alignment: .top, spacing: 10) {
            handle(in: size)
            latchedChips
        }
        .environment(\.layoutDirection, corner.isLeading ? .leftToRight : .rightToLeft)
    }

    @ViewBuilder
    private var latchedChips: some View {
        if supported {
            ToolbarGlassRow(spacing: 7) {
                ForEach(Self.modifierChips, id: \.1) { modifier, glyph, name in
                    if controller.isLatched(modifier) {
                        modifierChip(modifier, glyph: glyph, name: name)
                    }
                }
                if controller.softKeyboardVisible {
                    softKeyboardChip
                }
            }
            .frame(height: Self.handleDiameter)
            .environment(\.layoutDirection, .leftToRight)
            .animation(Self.chipAnimation, value: controller.latched)
            .animation(Self.chipAnimation, value: controller.softKeyboardVisible)
        }
    }

    private var chipAnchor: UnitPoint { corner.isLeading ? .leading : .trailing }

    private var chipTransition: AnyTransition {
        .scale(scale: 0.4, anchor: chipAnchor).combined(with: .opacity)
    }

    private func modifierChip(_ modifier: WireModifiers, glyph: String, name: String) -> some View {
        Button {
            ToolbarHaptics.selectionHaptics.selectionChanged()
            controller.toggleLatch(modifier)
        } label: {
            Text(glyph)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: Self.chipDiameter, height: Self.chipDiameter)
                .foregroundStyle(Color.white)
                .liquidGlass(in: Circle(), tint: .accentColor)
        }
        .buttonStyle(.plain)
        .transition(chipTransition)
        .accessibilityLabel("\(name) active")
        .accessibilityHint("Tap to release")
    }

    private var softKeyboardChip: some View {
        Button {
            ToolbarHaptics.selectionHaptics.selectionChanged()
            controller.setSoftKeyboardVisible(false)
        } label: {
            Image(systemName: "keyboard.chevron.compact.down")
                .font(.system(size: 15, weight: .medium))
                .frame(width: Self.chipDiameter, height: Self.chipDiameter)
                .foregroundStyle(.primary)
                .liquidGlass(in: Circle())
        }
        .buttonStyle(.plain)
        .transition(chipTransition)
        .accessibilityLabel("Soft keyboard active")
        .accessibilityHint("Tap to hide the keyboard")
    }

    private func handle(in size: CGSize) -> some View {
        Image(systemName: "slider.horizontal.3")
            .font(.system(size: 16, weight: .semibold))
            .frame(width: Self.handleDiameter, height: Self.handleDiameter)
            .foregroundStyle(handleTint)
            .liquidGlass(in: Circle())
            .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
            .contentShape(Circle())
            .scaleEffect(dragging ? 1.12 : 1)
            .animation(.easeOut(duration: 0.12), value: dragging)
            .environment(\.layoutDirection, .leftToRight)
            .gesture(dragGesture(in: size))
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(controller.expanded ? "Hide input controls" : "Show input controls")
            .accessibilityHint("Drag to move the toolbar to another corner")
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.dragSpace))
            .onChanged { value in
                if touching {
                    velocitySampler.record(translation: value.translation, at: value.time)
                } else {
                    touching = true
                    settle.stop()
                    dragBase = dragOffset
                    velocitySampler.begin(translation: value.translation, at: value.time)
                    ToolbarHaptics.selectionHaptics.prepare()
                }
                if !dragging,
                   hypot(value.translation.width, value.translation.height) > Self.dragSlop {
                    dragging = true
                    ToolbarHaptics.selectionHaptics.selectionChanged()
                }
                dragOffset = offset(for: value.translation)
            }
            .onEnded { value in
                guard touching else { return }
                touching = false
                velocitySampler.record(translation: value.translation, at: value.time)
                let released = offset(for: value.translation)
                dragOffset = released
                guard dragging else {
                    settle.start(from: released, velocity: .zero) { dragOffset = $0 }
                    withAnimation(ToolbarMotion.expand) {
                        controller.expanded.toggle()
                    }
                    return
                }
                dragging = false
                dock(released, velocity: velocitySampler.release(at: value.time), in: size)
            }
    }

    private func offset(for translation: CGSize) -> CGSize {
        CGSize(width: dragBase.width + translation.width,
               height: dragBase.height + translation.height)
    }

    private func dock(_ released: CGSize, velocity: CGSize, in size: CGSize) {
        let origin = dockedHandleCenter(for: corner, in: size)
        let handle = CGPoint(x: origin.x + released.width, y: origin.y + released.height)
        let projected = CGPoint(x: handle.x + velocity.width * Self.flickProjection,
                                y: handle.y + velocity.height * Self.flickProjection)
        let target = ToolbarCorner.nearest(to: projected, in: size)
        let landing = dockedHandleCenter(for: target, in: size)
        let rebased = CGSize(width: handle.x - landing.x, height: handle.y - landing.y)
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            dockedCorner = target.rawValue
            dragOffset = rebased
        }
        settle.start(from: rebased, velocity: velocity) { dragOffset = $0 }
    }

    private func dockedHandleCenter(for corner: ToolbarCorner, in size: CGSize) -> CGPoint {
        let insets = dockInsets(for: corner)
        let half = Self.handleDiameter / 2
        return CGPoint(
            x: corner.isLeading ? insets.leading + half
                                : size.width - insets.trailing - half,
            y: corner.isTop ? insets.top + half
                            : size.height - insets.bottom - half)
    }

    private var handleTint: Color {
        if !supported { return .orange }
        return controller.latched.isEmpty ? .primary : .accentColor
    }
}

struct ToolbarChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.08 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct DockedInputBar: View {

    @ObservedObject var controller: InputController
    @ObservedObject var actions = QuickActionStore.shared
    let supported: Bool
    let bottomInset: CGFloat
    let collapse: () -> Void
    let openSettings: () -> Void
    let disconnect: () -> Void

    @AppStorage("touchInputMode") private var touchInputMode = "direct"

    private static let buttonHeight: CGFloat = 34
    private static let buttonWidth: CGFloat = 40
    private static let collapseDiameter: CGFloat = 44
    private static let spacing: CGFloat = 7
    private static let fadeWidth: CGFloat = 16
    private static let chipVerticalPadding: CGFloat = 6
    private static let scrollerHeight: CGFloat = collapseDiameter + chipVerticalPadding * 2
    private static let containerVerticalPadding: CGFloat = 4

    private var chipShape: Capsule { Capsule(style: .continuous) }

    private var barShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
    }

    var body: some View {
        HStack(spacing: Self.spacing) {
            collapseButton
            if supported {
                actionScroller
            } else {
                unsupportedNote
                settingsButton
                disconnectButton
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Self.containerVerticalPadding)
        .frame(maxWidth: .infinity)
        .liquidGlass(in: barShape, interactive: false)
        .padding(.horizontal, 10)
        .padding(.bottom, max(bottomInset, 10))
        .environment(\.colorScheme, .dark)
    }

    private var actionScroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ToolbarGlassRow(spacing: Self.spacing) {
                keyboardButton
                ForEach(actions.items) { item in
                    itemView(item)
                }
                separator
                settingsButton
                disconnectButton
            }
            .padding(.horizontal, 8)
            .padding(.vertical, Self.chipVerticalPadding)
        }
        .scrollClipDisabledIfNeeded()
        .frame(height: Self.scrollerHeight)
        .mask { scrollFade }
    }

    private var scrollFade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: Self.fadeWidth)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: Self.fadeWidth)
        }
    }

    @ViewBuilder
    private func itemView(_ item: ToolbarActionItem) -> some View {
        switch item.kind {
        case .separator:
            separator
        case .builtin:
            if let action = item.builtin { builtinView(action) }
        case .combo:
            if let preset = item.combo {
                comboButton(symbol: preset.symbol, label: nil, name: preset.title,
                            mods: preset.modifiers, key: preset.key)
            }
        case .custom:
            if let key = item.key, !key.isEmpty {
                comboButton(symbol: item.symbol, label: item.label, name: item.title,
                            mods: item.wireModifiers, key: key)
            }
        }
    }

    @ViewBuilder
    private func builtinView(_ action: ToolbarBuiltin) -> some View {
        if action == .pointerMode {
            pointerModeButton
        } else if let modifier = action.modifier {
            modifierButton(modifier, glyph: action.glyph ?? "", name: action.title)
        } else if let key = action.key {
            if let symbol = action.symbol {
                keyButton(symbol: symbol) { controller.tapKey(key) }
                    .accessibilityLabel(action.title)
            } else {
                labelButton(action.glyph ?? action.title) { controller.tapKey(key) }
                    .accessibilityLabel(action.title)
            }
        }
    }

    private func comboButton(symbol: String?, label: String?, name: String,
                             mods: WireModifiers, key: String) -> some View {
        let glyph = (symbol ?? "").trimmingCharacters(in: .whitespaces)
        let title = (label ?? "").trimmingCharacters(in: .whitespaces)
        let tap = {
            ToolbarHaptics.selectionHaptics.selectionChanged()
            controller.tapCombo(mods: mods, key: key)
        }
        return Group {
            if glyph.isEmpty {
                labelButton(title.isEmpty ? name : title, action: tap)
            } else {
                keyButton(symbol: glyph, action: tap)
            }
        }
        .accessibilityLabel(name)
    }

    private var collapseButton: some View {
        Button(action: collapse) {
            Image(systemName: "chevron.down")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: Self.collapseDiameter, height: Self.collapseDiameter)
                .foregroundStyle(controller.latched.isEmpty ? Color.primary : Color.accentColor)
                .liquidGlass(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Hide input controls")
    }

    private var settingsButton: some View {
        keyButton(symbol: "gearshape", action: openSettings)
            .accessibilityLabel("Settings")
    }

    private var keyboardButton: some View {
        keyButton(symbol: controller.softKeyboardVisible
                  ? "keyboard.chevron.compact.down" : "keyboard",
                  active: controller.softKeyboardVisible) {
            controller.toggleSoftKeyboard()
        }
        .accessibilityLabel("Keyboard")
        .accessibilityAddTraits(controller.softKeyboardVisible ? [.isSelected] : [])
    }

    private var unsupportedNote: some View {
        Text("Keyboard and right-click need a newer Remotely on your Mac.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    private var separator: some View {
        Capsule()
            .fill(Color(.separator))
            .frame(width: 1, height: 20)
            .padding(.horizontal, 3)
            .accessibilityHidden(true)
    }

    private func modifierButton(_ modifier: WireModifiers, glyph: String, name: String) -> some View {
        let active = controller.isLatched(modifier)
        return Button {
            controller.toggleLatch(modifier)
            ToolbarHaptics.selectionHaptics.selectionChanged()
        } label: {
            Text(glyph)
                .font(.body.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: Self.buttonWidth, height: Self.buttonHeight)
                .foregroundStyle(active ? Color.white : Color.primary)
                .liquidGlass(in: chipShape, tint: active ? .accentColor : nil, interactive: false)
        }
        .buttonStyle(ToolbarChipButtonStyle())
        .accessibilityLabel(name)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    private func labelButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 11)
                .frame(minWidth: Self.buttonWidth, minHeight: Self.buttonHeight,
                       maxHeight: Self.buttonHeight)
                .foregroundStyle(Color.primary)
                .liquidGlass(in: chipShape, interactive: false)
        }
        .buttonStyle(ToolbarChipButtonStyle())
    }

    private func keyButton(symbol: String, active: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.medium))
                .frame(width: Self.buttonWidth, height: Self.buttonHeight)
                .foregroundStyle(active ? Color.white : Color.primary)
                .liquidGlass(in: chipShape, tint: active ? .accentColor : nil, interactive: false)
        }
        .buttonStyle(ToolbarChipButtonStyle())
    }

    private var disconnectButton: some View {
        Button {
            ToolbarHaptics.impactHaptics.impactOccurred()
            controller.reset()
            disconnect()
        } label: {
            Image(systemName: "power")
                .font(.subheadline.weight(.semibold))
                .frame(width: Self.buttonWidth, height: Self.buttonHeight)
                .foregroundStyle(Color.white)
                .liquidGlass(in: chipShape, tint: .red, interactive: false)
        }
        .buttonStyle(ToolbarChipButtonStyle())
        .accessibilityLabel("Disconnect")
        .accessibilityHint("Ends the session and returns to the Mac list")
    }

    private var pointerModeButton: some View {
        let active = touchInputMode == "pointer"
        return keyButton(symbol: "cursorarrow", active: active) {
            touchInputMode = active ? "direct" : "pointer"
            ToolbarHaptics.selectionHaptics.selectionChanged()
        }
        .accessibilityLabel("Pointer mode")
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

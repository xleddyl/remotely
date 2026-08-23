import AVFoundation
import SwiftUI
import UIKit

// MARK: - Touch sampling

extension UIEvent {
    /// Every position UIKit recorded for `touch` in this update, oldest first.
    ///
    /// The panel samples faster than UIKit delivers, so a single `touchesMoved`
    /// stands for several real positions. This batch is that whole history and
    /// its *last* entry is `touch` itself, so forward the list as it comes:
    /// sending `touch` alongside it puts the newest sample ahead of its own
    /// history and emits it twice, which reads as backtracking on fast strokes.
    /// Falls back to the touch alone when UIKit coalesced nothing.
    func samples(for touch: UITouch) -> [UITouch] {
        let batch = coalescedTouches(for: touch) ?? []
        return batch.isEmpty ? [touch] : batch
    }
}

// MARK: - Video layer host view

/// UIView whose backing layer is the AVSampleBufferDisplayLayer.
/// Forwards touches as normalized video-space coordinates (touchscreen mode).
struct VideoLayerView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer
    let receiver: PhoneReceiver
    let input: InputController
    @AppStorage("touchInputMode") var touchInputMode = "pointer"
    @AppStorage("pointerSpeed") var pointerSpeed = 1.0

    func makeUIView(context: Context) -> VideoView {
        let view = VideoView()
        view.backgroundColor = .black
        view.isMultipleTouchEnabled = true
        view.clipsToBounds = true
        view.receiver = receiver
        view.input = input
        view.pointerModeEnabled = touchInputMode == "pointer"
        view.pointerSpeed = pointerSpeed

        view.attachContent(displayLayer)

        view.inputEngine.normalize = { [weak view] point in view?.normalized(point) }
        view.inputEngine.onPencil = { [weak receiver] phase, x, y, pressure, azimuth, altitude in
            receiver?.sendPencil(phase: phase, x: x, y: y,
                                 pressure: pressure, azimuth: azimuth,
                                 altitude: altitude)
        }
        view.inputEngine.onProximity = { [weak receiver] entering, x, y in
            receiver?.sendProximity(entering: entering, x: x, y: y)
        }
        view.inputEngine.install(on: view)

        let pan = UIPanGestureRecognizer(target: view, action: #selector(VideoView.didTwoFingerPan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        view.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: view, action: #selector(VideoView.didPinch(_:)))
        pinch.delegate = view
        view.addGestureRecognizer(pinch)

        let twoFingerTap = UITapGestureRecognizer(
            target: view, action: #selector(VideoView.didTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.numberOfTapsRequired = 1
        view.addGestureRecognizer(twoFingerTap)

        let longPress = UILongPressGestureRecognizer(
            target: view, action: #selector(VideoView.didLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        longPress.allowableMovement = 12
        longPress.numberOfTouchesRequired = 1
        view.addGestureRecognizer(longPress)

        view.installKeyboardInput()
        input.presentSoftKeyboard = { [weak view] in view?.focusSoftKeyboard() }
        input.dismissSoftKeyboard = { [weak view] in view?.releaseSoftKeyboard() }

        // Local cursor echo: position updates ride the ~2ms control path
        // instead of the ~30ms video path, so the pointer feels native.
        receiver.onCursor = { [weak view] x, y, visible in
            view?.moveCursor(x: x, y: y, visible: visible)
        }
        receiver.onCursorImage = { [weak view] image, anchor, normSize in
            view?.setCursorSprite(image, anchor: anchor, normSize: normSize)
        }
        receiver.onDisconnect = { [weak view] in view?.resetGestureState() }
        return view
    }

    func updateUIView(_ uiView: VideoView, context: Context) {
        uiView.pointerModeEnabled = touchInputMode == "pointer"
        uiView.pointerSpeed = pointerSpeed
        // videoSize arrives after the format description — re-fit the layers.
        uiView.setNeedsLayout()
    }

    final class VideoView: UIView, UIGestureRecognizerDelegate {
        weak var receiver: PhoneReceiver?
        weak var input: InputController?
        var pointerModeEnabled = false { didSet { pointerModeDidChange(from: oldValue) } }
        var pointerSpeed: Double = 1.0
        let inputEngine = InputCaptureEngine()
        private let keyboardInput = KeyboardInputView()

        private var wireMods: Int { input?.wireMods ?? 0 }

        func installKeyboardInput() {
            keyboardInput.frame = .zero
            addSubview(keyboardInput)
            keyboardInput.onText = { [weak self] text in self?.input?.insertText(text) }
            keyboardInput.onKeyName = { [weak self] name in self?.input?.tapKey(name) }
            keyboardInput.onWordDelete = { [weak self] in self?.input?.tapCombo(mods: [.option], key: "delete") }
            keyboardInput.onPresses = { [weak self] presses, down in
                self?.input?.handlePresses(presses, down: down, allowText: false) ?? false
            }
            keyboardInput.onResign = { [weak self] in
                self?.input?.setSoftKeyboardVisible(false)
                self?.becomeHardwareKeyResponder()
            }
        }

        func focusSoftKeyboard() {
            keyboardInput.becomeFirstResponder()
        }

        func releaseSoftKeyboard() {
            let ownedKeyboard = keyboardInput.isFirstResponder
            _ = keyboardInput.resignFirstResponder()
            if !ownedKeyboard {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                to: nil, from: nil, for: nil)
            }
            becomeHardwareKeyResponder()
        }

        private func becomeHardwareKeyResponder() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil,
                      !self.keyboardInput.isFirstResponder,
                      !self.isFirstResponder else { return }
                self.becomeFirstResponder()
            }
        }

        override var canBecomeFirstResponder: Bool { true }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            becomeHardwareKeyResponder()
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if input?.handlePresses(presses, down: true, allowText: true) == true { return }
            super.pressesBegan(presses, with: event)
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if input?.handlePresses(presses, down: false, allowText: true) == true { return }
            super.pressesEnded(presses, with: event)
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if input?.handlePresses(presses, down: false, allowText: true) == true { return }
            super.pressesCancelled(presses, with: event)
        }

        private let cursorLayer: CALayer = {
            let layer = CALayer()
            layer.isHidden = true
            layer.zPosition = 10
            // Position updates arrive at 120Hz — implicit animations would
            // smear the cursor behind every move.
            layer.actions = ["position": NSNull(), "contents": NSNull(),
                             "bounds": NSNull(), "hidden": NSNull()]
            return layer
        }()
        private var cursorNormSize = CGSize.zero
        private var cursorNorm = CGPoint(x: 0.5, y: 0.5)
        private var cursorVisible = false

        private let contentLayer: CALayer = {
            let layer = CALayer()
            layer.anchorPoint = .zero
            return layer
        }()
        private weak var videoLayer: CALayer?

        func attachContent(_ layer: CALayer) {
            videoLayer = layer
            layer.frame = bounds
            contentLayer.frame = bounds
            contentLayer.addSublayer(layer)
            contentLayer.addSublayer(cursorLayer)
            self.layer.addSublayer(contentLayer)
        }

        private var lastLoggedLayout = ""
        private var lastVideoSize = CGSize.zero

        override func layoutSubviews() {
            super.layoutSubviews()
            let video = receiver?.videoSize ?? .zero
            if video != lastVideoSize {
                lastVideoSize = video
                resetZoom()
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentLayer.bounds = CGRect(origin: .zero, size: bounds.size)
            contentLayer.position = .zero
            // AVSBDL aspect-fits internally (videoGravity) — full bounds.
            videoLayer?.frame = contentLayer.bounds
            if cursorLayer.superlayer == nil { contentLayer.addSublayer(cursorLayer) }
            applyZoomTransform()
            updateCursorLayout()
            CATransaction.commit()
            // Rotation diagnostics — one line per layout change.
            let line = "layout: bounds=\(Int(bounds.width))x\(Int(bounds.height))"
                + " video=\(Int(video.width))x\(Int(video.height))"
                + " layer=\(Int(videoLayer?.frame.width ?? -1))x\(Int(videoLayer?.frame.height ?? -1))"
            if line != lastLoggedLayout {
                lastLoggedLayout = line
                Log.info(line)
            }
            if let window {
                receiver?.setWindowSafeArea(window.safeAreaInsets)
            }
        }

        private var zoomScale: CGFloat = 1
        private var zoomOffset = CGPoint.zero
        private var pinchActive = false
        private var pinchSuppressesScroll = false
        private var pinchStartScale: CGFloat = 1
        private var pinchStartOffset = CGPoint.zero
        private var pinchAnchor = CGPoint.zero

        private let minZoom: CGFloat = 1
        private let maxZoom: CGFloat = 4
        private let zoomSnapsBackBelow: CGFloat = 1.15
        private let pinchScrollSlop: CGFloat = 0.06

        private func applyZoomTransform() {
            var transform = CATransform3DMakeTranslation(zoomOffset.x, zoomOffset.y, 0)
            transform = CATransform3DScale(transform, zoomScale, zoomScale, 1)
            contentLayer.transform = transform
        }

        private func clampedZoomOffset(_ offset: CGPoint, scale: CGFloat) -> CGPoint {
            CGPoint(x: min(0, max(bounds.width * (1 - scale), offset.x)),
                    y: min(0, max(bounds.height * (1 - scale), offset.y)))
        }

        private func setZoom(scale: CGFloat, offset: CGPoint) {
            zoomScale = min(max(scale, minZoom), maxZoom)
            zoomOffset = clampedZoomOffset(offset, scale: zoomScale)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            applyZoomTransform()
            CATransaction.commit()
        }

        private func resetZoom() {
            pinchSuppressesScroll = false
            setZoom(scale: 1, offset: .zero)
        }

        private func snapZoomBack() {
            zoomScale = 1
            zoomOffset = .zero
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.22)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            applyZoomTransform()
            CATransaction.commit()
        }

        private func contentPoint(_ point: CGPoint) -> CGPoint {
            guard zoomScale != 1 else { return point }
            return CGPoint(x: (point.x - zoomOffset.x) / zoomScale,
                           y: (point.y - zoomOffset.y) / zoomScale)
        }

        @objc func didPinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                pinchActive = true
                pinchStartScale = zoomScale
                pinchStartOffset = zoomOffset
                pinchAnchor = recognizer.location(in: self)
                if zoomScale > 1 { pinchSuppressesScroll = true }
            case .changed:
                guard pinchActive else { return }
                if abs(recognizer.scale - 1) > pinchScrollSlop { pinchSuppressesScroll = true }
                let scale = min(max(pinchStartScale * recognizer.scale, minZoom), maxZoom)
                let anchor = CGPoint(x: (pinchAnchor.x - pinchStartOffset.x) / pinchStartScale,
                                     y: (pinchAnchor.y - pinchStartOffset.y) / pinchStartScale)
                let centroid = recognizer.location(in: self)
                setZoom(scale: scale,
                        offset: CGPoint(x: centroid.x - anchor.x * scale,
                                        y: centroid.y - anchor.y * scale))
            default:
                guard pinchActive else { return }
                pinchActive = false
                guard zoomScale < zoomSnapsBackBelow else { return }
                snapZoomBack()
                pinchSuppressesScroll = true
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            gestureRecognizer is UIPinchGestureRecognizer && other is UIPanGestureRecognizer
        }

        private func videoFitScale(_ video: CGSize) -> CGFloat {
            min(bounds.width / video.width, bounds.height / video.height)
        }

        /// Aspect-fit rect of the video inside the view (inverse of normalized()).
        private func videoRect() -> CGRect? {
            guard let video = receiver?.videoSize, video != .zero,
                  bounds.width > 0, bounds.height > 0 else { return nil }
            let scale = videoFitScale(video)
            let size = CGSize(width: video.width * scale, height: video.height * scale)
            return CGRect(x: (bounds.width - size.width) / 2,
                          y: (bounds.height - size.height) / 2,
                          width: size.width, height: size.height)
        }

        // The video is aspect-fit inside the view; map view coords into the
        // displayed video rect and normalize to [0,1].
        fileprivate func normalized(_ point: CGPoint) -> (x: Double, y: Double)? {
            guard let rect = videoRect() else { return nil }
            let content = contentPoint(point)
            return (Double(clamp01((content.x - rect.minX) / rect.width)),
                    Double(clamp01((content.y - rect.minY) / rect.height)))
        }

        private func clamp01<Value: FloatingPoint>(_ value: Value) -> Value {
            min(max(value, 0), 1)
        }

        func resetGestureState() {
            discardPendingDown()
            cancelPointerGesture()
            pointerLastTapAt = 0
            rightClickActive = false
            twoFingerActive = false
            pinchActive = false
            resetZoom()
        }

        func moveCursor(x: Double, y: Double, visible: Bool) {
            cursorNorm = CGPoint(x: x, y: y)
            cursorVisible = visible
            if pointerTouch == nil { virtualCursor = cursorNorm }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cursorLayer.isHidden = !visible || cursorLayer.contents == nil
            updateCursorLayout()
            CATransaction.commit()
        }

        func setCursorSprite(_ image: UIImage, anchor: CGPoint, normSize: CGSize) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cursorLayer.contents = image.cgImage
            cursorLayer.anchorPoint = anchor
            cursorNormSize = normSize
            cursorLayer.isHidden = !cursorVisible
            updateCursorLayout()
            CATransaction.commit()
        }

        private func updateCursorLayout() {
            guard let rect = videoRect(), cursorNormSize != .zero else { return }
            cursorLayer.bounds = CGRect(x: 0, y: 0,
                                        width: cursorNormSize.width * rect.width,
                                        height: cursorNormSize.height * rect.height)
            cursorLayer.position = CGPoint(x: rect.minX + cursorNorm.x * rect.width,
                                           y: rect.minY + cursorNorm.y * rect.height)
        }

        private func isFinger(_ touch: UITouch) -> Bool {
            switch touch.type {
            case .direct, .indirectPointer: return true
            default: return false
            }
        }

        private func isPencil(_ touch: UITouch) -> Bool {
            touch.type == .pencil
        }

        private func ownsFinger(_ touch: UITouch) -> Bool {
            guard isFinger(touch), let view = touch.view else { return false }
            return view === self || view.isDescendant(of: self)
        }

        private func liveFingersOnVideo(in event: UIEvent?) -> Int {
            guard let all = event?.allTouches else { return 1 }
            return all.filter {
                ownsFinger($0) && $0.phase != .ended && $0.phase != .cancelled
            }.count
        }

        private var twoFingerActive = false
        private var lastPan = CGPoint.zero
        private var lastNorm: (x: Double, y: Double) = (0.5, 0.5)

        @objc func didTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
            guard let video = receiver?.videoSize, video != .zero else { return }
            switch recognizer.state {
            case .began:
                twoFingerActive = true
                lastPan = .zero
                if !pinchActive { pinchSuppressesScroll = false }
                if pointerModeEnabled {
                    cancelPointerGesture()
                    pointerLastTapAt = 0
                    return
                }
                guard zoomScale == 1, !pinchActive else { return }
                // macOS delivers scroll to whatever sits under the cursor, and
                // the cursor no longer follows the fingers now that a press is
                // withheld until it commits. Put it on the gesture once, up
                // front, so the scroll lands on the window being touched. Once
                // only: a real trackpad does not drag the cursor while
                // scrolling, and moving it mid-gesture would change the target.
                if let norm = normalized(recognizer.location(in: self)) {
                    lastNorm = norm
                    receiver?.sendTouch(phase: "moved", x: norm.x, y: norm.y, mods: wireMods)
                }
            case .changed:
                let translation = recognizer.translation(in: self)
                let delta = CGPoint(x: translation.x - lastPan.x, y: translation.y - lastPan.y)
                lastPan = translation
                if pinchActive { return }
                if zoomScale > 1 {
                    setZoom(scale: zoomScale,
                            offset: CGPoint(x: zoomOffset.x + delta.x,
                                            y: zoomOffset.y + delta.y))
                    return
                }
                guard !pinchSuppressesScroll else { return }
                let scale = videoFitScale(video)
                // Deltas in video pixels, natural-scrolling direction.
                receiver?.sendScroll(dx: delta.x / scale, dy: delta.y / scale,
                                     mods: wireMods)
            default:
                twoFingerActive = false
            }
        }

        @objc func didLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, !twoFingerActive, !pointerModeEnabled,
                  receiver?.macSupportsKeyboardWire == true,
                  !inputEngine.hasActivePen else { return }
            rightClickAtDirectLocation(recognizer.location(in: self))
        }

        @objc func didTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, !twoFingerActive,
                  receiver?.macSupportsKeyboardWire == true,
                  !inputEngine.hasActivePen else { return }
            if pointerModeEnabled {
                rightClickAtVirtualCursor()
                return
            }
            rightClickAtDirectLocation(recognizer.location(in: self))
        }

        private func rightClickAtDirectLocation(_ point: CGPoint) {
            guard let norm = normalized(point) else { return }
            if downSent {
                receiver?.sendTouch(phase: "cancelled", x: lastNorm.x, y: lastNorm.y, mods: wireMods)
            }
            discardPendingDown()
            rightClickActive = true
            lastNorm = norm
            let mods = wireMods
            receiver?.sendMouse(button: "right", phase: "down", x: norm.x, y: norm.y, mods: mods)
            receiver?.sendMouse(button: "right", phase: "up", x: norm.x, y: norm.y, mods: mods)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }

        // A press is only a click once we know a second finger is not coming.
        // Sending `began` on contact posted a mouse-down we then had to take
        // back, and taking it back only works when UIKit happens to deliver
        // `cancelled`; when the pan recognizer misses and we get a plain
        // `ended` instead, that down/up pair *is* a click, which is why every
        // other two-finger scroll opened whatever sat under the first finger.
        // So hold the down until the gesture commits to being one.
        private var pendingDown: (x: Double, y: Double)?
        private var downSent = false
        private var holdTimer: DispatchWorkItem?
        private var rightClickActive = false

        /// Movement (in points) that turns a held press into a drag.
        private let dragSlop: CGFloat = 10
        /// A press this long with no second finger is a deliberate hold, so
        /// commit it: press-and-hold menus and drag handles need the button.
        private let holdDelay: TimeInterval = 0.12
        private var pendingDownPoint: CGPoint = .zero

        /// Emit the withheld `began`, at the point the finger first landed so a
        /// drag starts where the user touched rather than where slop was crossed.
        private func commitPendingDown() {
            guard let down = pendingDown, !downSent else { return }
            downSent = true
            holdTimer?.cancel()
            holdTimer = nil
            receiver?.sendTouch(phase: "began", x: down.x, y: down.y, mods: wireMods)
        }

        /// Drop the press without a trace. Nothing reached the Mac, so there is
        /// no button to release and no click to suppress.
        private func discardPendingDown() {
            pendingDown = nil
            downSent = false
            holdTimer?.cancel()
            holdTimer = nil
        }

        private func sendDirectTouch(_ phase: String, _ touches: Set<UITouch>, _ event: UIEvent?) {
            let fingers = touches.filter { isFinger($0) }
            guard !fingers.isEmpty else { return }
            if phase == "began" { rightClickActive = false }
            if rightClickActive {
                if phase == "ended" || phase == "cancelled" { rightClickActive = false }
                return
            }
            // Ignore single-finger events while a two-finger gesture runs,
            // and end the click if a second finger joins mid-press.
            if twoFingerActive || liveFingersOnVideo(in: event) > 1 {
                if downSent {
                    receiver?.sendTouch(phase: "cancelled", x: lastNorm.x, y: lastNorm.y,
                                        mods: wireMods)
                }
                discardPendingDown()
                return
            }
            guard let touch = fingers.first,
                  let norm = normalized(touch.location(in: self)) else { return }
            lastNorm = norm

            switch phase {
            case "began":
                let location = touch.location(in: self)
                pendingDown = norm
                pendingDownPoint = location
                downSent = false
                let work = DispatchWorkItem { [weak self] in self?.commitPendingDown() }
                holdTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: work)
                return
            case "ended":
                // A tap: nothing was posted yet, so post the whole click now.
                if pendingDown != nil, !downSent { commitPendingDown() }
                // No down means the press was already discarded (a second
                // finger took it), so there is nothing to release.
                if downSent {
                    receiver?.sendTouch(phase: "ended", x: norm.x, y: norm.y, mods: wireMods)
                }
                discardPendingDown()
                return
            case "cancelled":
                if downSent {
                    receiver?.sendTouch(phase: "cancelled", x: norm.x, y: norm.y, mods: wireMods)
                }
                discardPendingDown()
                return
            case "moved":
                if pendingDown != nil, !downSent {
                    let moved = hypot(touch.location(in: self).x - pendingDownPoint.x,
                                      touch.location(in: self).y - pendingDownPoint.y)
                    // Below slop the finger is still deciding: track the cursor
                    // (the Mac turns a move without a down into mouseMoved) but
                    // keep the button up so a second finger can still cancel.
                    if moved > dragSlop { commitPendingDown() }
                }
            default:
                break
            }

            if phase == "moved", let event {
                // Forward every coalesced sample so the Mac gets the full-rate
                // drag.
                let mods = wireMods
                for sample in event.samples(for: touch) {
                    if let norm = normalized(sample.location(in: self)) {
                        lastNorm = norm
                        receiver?.sendTouch(phase: "moved", x: norm.x, y: norm.y, mods: mods)
                    }
                }
                return
            }
            receiver?.sendTouch(phase: phase, x: norm.x, y: norm.y, mods: wireMods)
        }

        private var virtualCursor = CGPoint(x: 0.5, y: 0.5)
        private var pointerTouch: UITouch?
        private var pointerStartPoint = CGPoint.zero
        private var pointerLastPoint = CGPoint.zero
        private var pointerStartedAt: TimeInterval = 0
        private var pointerTravel: CGFloat = 0
        private var pointerTapEligible = false
        private var pointerButtonDown = false
        private var pointerClickSuppressed = false
        private var pointerLastTapAt: TimeInterval = 0

        private let pointerTapDuration: TimeInterval = 0.5
        private let pointerTapSlop: CGFloat = 10
        private let pointerTapDragWindow: TimeInterval = 0.35

        private func pointerModeDidChange(from wasEnabled: Bool) {
            guard pointerModeEnabled != wasEnabled else { return }
            if downSent {
                receiver?.sendTouch(phase: "cancelled", x: lastNorm.x, y: lastNorm.y,
                                    mods: wireMods)
            }
            discardPendingDown()
            cancelPointerGesture()
            pointerLastTapAt = 0
            rightClickActive = false
            virtualCursor = cursorNorm
        }

        private func resetPointerGesture() {
            pointerTouch = nil
            pointerButtonDown = false
            pointerTapEligible = false
            pointerClickSuppressed = false
            pointerTravel = 0
        }

        private func cancelPointerGesture() {
            if pointerButtonDown {
                receiver?.sendTouch(phase: "cancelled", x: virtualCursor.x, y: virtualCursor.y,
                                    mods: wireMods)
            }
            resetPointerGesture()
        }

        private func rightClickAtVirtualCursor() {
            if pointerButtonDown {
                receiver?.sendTouch(phase: "cancelled", x: virtualCursor.x, y: virtualCursor.y,
                                    mods: wireMods)
                pointerButtonDown = false
            }
            pointerClickSuppressed = true
            pointerTapEligible = false
            pointerLastTapAt = 0
            let mods = wireMods
            receiver?.sendMouse(button: "right", phase: "down",
                                x: virtualCursor.x, y: virtualCursor.y, mods: mods)
            receiver?.sendMouse(button: "right", phase: "up",
                                x: virtualCursor.x, y: virtualCursor.y, mods: mods)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }

        private func sendPointer(_ phase: String, _ touches: Set<UITouch>, _ event: UIEvent?) {
            let fingers = touches.filter { isFinger($0) }
            guard !fingers.isEmpty else { return }

            switch phase {
            case "began":
                if twoFingerActive || liveFingersOnVideo(in: event) > 1 {
                    cancelPointerGesture()
                    pointerLastTapAt = 0
                    return
                }
                guard let touch = fingers.first else { return }
                beginPointerGesture(touch)
            case "moved":
                if twoFingerActive || liveFingersOnVideo(in: event) > 1 {
                    cancelPointerGesture()
                    pointerLastTapAt = 0
                    return
                }
                if pointerTouch == nil, let touch = fingers.first {
                    adoptPointerGesture(touch)
                }
                guard let touch = pointerTouch, fingers.contains(touch) else { return }
                movePointer(touch, event)
            case "ended":
                guard let touch = pointerTouch, fingers.contains(touch) else { return }
                endPointerGesture(touch)
            case "cancelled":
                guard let touch = pointerTouch, fingers.contains(touch) else { return }
                cancelPointerGesture()
                pointerLastTapAt = 0
            default:
                break
            }
        }

        private func beginPointerGesture(_ touch: UITouch) {
            let now = CACurrentMediaTime()
            pointerTouch = touch
            pointerStartPoint = touch.location(in: self)
            pointerLastPoint = pointerStartPoint
            pointerStartedAt = now
            pointerTravel = 0
            pointerTapEligible = true
            pointerClickSuppressed = false
            pointerButtonDown = false
            if now - pointerLastTapAt < pointerTapDragWindow {
                pointerLastTapAt = 0
                pointerButtonDown = true
                receiver?.sendTouch(phase: "began", x: virtualCursor.x, y: virtualCursor.y,
                                    mods: wireMods)
            }
        }

        private func adoptPointerGesture(_ touch: UITouch) {
            pointerTouch = touch
            pointerStartPoint = touch.location(in: self)
            pointerLastPoint = pointerStartPoint
            pointerStartedAt = CACurrentMediaTime()
            pointerTravel = 0
            pointerTapEligible = false
            pointerClickSuppressed = false
            pointerButtonDown = false
        }

        private func movePointer(_ touch: UITouch, _ event: UIEvent?) {
            guard let rect = videoRect(), rect.width > 0, rect.height > 0 else { return }
            let mods = wireMods
            let speed = CGFloat(pointerSpeed)
            for sample in event?.samples(for: touch) ?? [touch] {
                let point = sample.location(in: self)
                let dx = (point.x - pointerLastPoint.x) / rect.width * speed
                let dy = (point.y - pointerLastPoint.y) / rect.height * speed
                pointerLastPoint = point
                virtualCursor = CGPoint(x: clamp01(virtualCursor.x + dx),
                                        y: clamp01(virtualCursor.y + dy))
                receiver?.sendTouch(phase: "moved", x: virtualCursor.x, y: virtualCursor.y,
                                    mods: mods)
            }
            pointerTravel = max(pointerTravel,
                                hypot(pointerLastPoint.x - pointerStartPoint.x,
                                      pointerLastPoint.y - pointerStartPoint.y))
        }

        private func endPointerGesture(_ touch: UITouch) {
            let point = touch.location(in: self)
            let travel = max(pointerTravel,
                             hypot(point.x - pointerStartPoint.x,
                                   point.y - pointerStartPoint.y))
            let now = CACurrentMediaTime()
            let isTap = pointerTapEligible
                && now - pointerStartedAt <= pointerTapDuration
                && travel < pointerTapSlop
            let mods = wireMods

            if pointerClickSuppressed {
                if pointerButtonDown {
                    receiver?.sendTouch(phase: "cancelled", x: virtualCursor.x, y: virtualCursor.y,
                                        mods: mods)
                }
                pointerLastTapAt = 0
                resetPointerGesture()
                return
            }
            if pointerButtonDown {
                receiver?.sendTouch(phase: "ended", x: virtualCursor.x, y: virtualCursor.y,
                                    mods: mods)
            } else if isTap {
                receiver?.sendTouch(phase: "began", x: virtualCursor.x, y: virtualCursor.y,
                                    mods: mods)
                receiver?.sendTouch(phase: "ended", x: virtualCursor.x, y: virtualCursor.y,
                                    mods: mods)
            }
            pointerLastTapAt = isTap ? now : 0
            resetPointerGesture()
        }

        private func sendPencilAsTouch(_ phase: String, _ touches: Set<UITouch>, _ event: UIEvent?) {
            guard let touch = touches.first,
                  let norm = normalized(touch.location(in: self)) else { return }
            lastNorm = norm
            if phase == "moved", let event {
                for sample in event.samples(for: touch) {
                    if let norm = normalized(sample.location(in: self)) {
                        lastNorm = norm
                        receiver?.sendTouch(phase: "moved", x: norm.x, y: norm.y)
                    }
                }
                return
            }
            receiver?.sendTouch(phase: phase, x: norm.x, y: norm.y)
        }

        private var penTouchDown = false

        private func routeTouches(_ phase: String, _ touches: Set<UITouch>, _ event: UIEvent?, ended: Bool) {
            let pencil = touches.filter { isPencil($0) }
            let finger = touches.filter { isFinger($0) }
            let usePencilWire = receiver?.macSupportsPencilWire ?? false

            if !pencil.isEmpty {
                penTouchDown = !ended
                if usePencilWire {
                    inputEngine.handle(pencil, event: event, ended: ended)
                } else {
                    sendPencilAsTouch(phase, pencil, event)
                }
            }
            // Palm rejection: ignore resting fingers while the pen is down.
            if !finger.isEmpty && !penTouchDown {
                if pointerModeEnabled {
                    sendPointer(phase, finger, event)
                } else {
                    sendDirectTouch(phase, finger, event)
                }
            }
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            routeTouches("began", touches, event, ended: false)
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            routeTouches("moved", touches, event, ended: false)
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            routeTouches("ended", touches, event, ended: true)
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            routeTouches("cancelled", touches, event, ended: true)
        }
    }
}

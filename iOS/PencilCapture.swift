import UIKit

// MARK: - Apple Pencil capture

/// Captures Apple Pencil hover and stroke on a host view.
/// Finger touches stay on VideoView's existing `touch` wire path.
final class InputCaptureEngine: NSObject {
    var onPencil: ((_ phase: String, _ x: Double, _ y: Double,
                    _ pressure: Double, _ azimuth: Double, _ altitude: Double) -> Void)?
    var onProximity: ((_ entering: Bool, _ x: Double, _ y: Double) -> Void)?

    /// True while at least one pen contact is on the glass (palm rejection).
    var hasActivePen: Bool { !activePens.isEmpty }

    /// Map a point in the host view to normalized video coordinates.
    var normalize: ((CGPoint) -> (x: Double, y: Double)?)?

    private weak var hostView: UIView?
    private var activePens: Set<UInt64> = []
    private var proximityActive = false

    func install(on view: UIView) {
        hostView = view
        view.isMultipleTouchEnabled = true

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hoverChanged(_:)))
        hover.allowedTouchTypes = [UITouch.TouchType.pencil.rawValue as NSNumber]
        view.addGestureRecognizer(hover)
    }

    @objc private func hoverChanged(_ gr: UIHoverGestureRecognizer) {
        guard activePens.isEmpty, let view = hostView else { return }
        guard let n = normalize?(gr.location(in: view)) else { return }
        switch gr.state {
        case .began:
            openProximity(x: n.x, y: n.y)
            fallthrough
        case .changed:
            let azimuth = Double(gr.azimuthAngle(in: view))
            let altitude = Double(gr.altitudeAngle)
            onPencil?("hover", n.x, n.y, 0, azimuth, altitude)
        case .ended, .cancelled, .failed:
            guard activePens.isEmpty else { return }
            closeProximity(x: n.x, y: n.y)
        default:
            break
        }
    }

    func handle(_ touches: Set<UITouch>, event: UIEvent?, ended: Bool) {
        guard hostView != nil else { return }
        for touch in touches where touch.type == .pencil {
            emitPen(touch, event: event, ended: ended)
        }
    }

    private func openProximity(x: Double, y: Double) {
        guard !proximityActive else { return }
        proximityActive = true
        onProximity?(true, x, y)
    }

    private func closeProximity(x: Double, y: Double) {
        guard proximityActive else { return }
        proximityActive = false
        onProximity?(false, x, y)
    }

    private func emitPen(_ touch: UITouch, event: UIEvent?, ended: Bool) {
        guard let view = hostView else { return }
        let id = UInt64(bitPattern: Int64(ObjectIdentifier(touch).hashValue))
        let loc = touch.location(in: view)
        guard let n = normalize?(loc) else { return }
        let (nx, ny) = (n.x, n.y)

        let pressure = min(Double(touch.force), 1.0)
        let azimuth = Double(touch.azimuthAngle(in: view))
        let altitude = Double(touch.altitudeAngle)

        if !ended && !activePens.contains(id) {
            activePens.insert(id)
            openProximity(x: nx, y: ny)
            emitPencil("down", x: nx, y: ny, pressure: pressure,
                       azimuth: azimuth, altitude: altitude)
            return
        }

        if !ended {
            for sample in event?.samples(for: touch) ?? [touch] {
                guard let n = normalize?(sample.location(in: view)) else { continue }
                emitPencil("move", x: n.x, y: n.y,
                           pressure: min(Double(sample.force), 1.0),
                           azimuth: Double(sample.azimuthAngle(in: view)),
                           altitude: Double(sample.altitudeAngle))
            }
            return
        }

        defer { activePens.remove(id) }
        emitPencil("up", x: nx, y: ny, pressure: 0,
                   azimuth: azimuth, altitude: altitude)
        closeProximity(x: nx, y: ny)
    }

    private func emitPencil(_ phase: String, x: Double, y: Double,
                            pressure: Double, azimuth: Double, altitude: Double) {
        onPencil?(phase, x, y, pressure, azimuth, altitude)
    }
}

import Foundation
import Network

final class PhoneConnectionListener {

    struct Accepted {
        let connection: NWConnection
        let hello: PhoneInfo
    }

    static let port: UInt16 = 9000
    static let serviceType = "_remotely._tcp"

    static let installID: String = {
        if let existing = UserDefaults.standard.string(forKey: "installID") {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: "installID")
        return fresh
    }()

    static var computerName: String {
        let name = Host.current().localizedName ?? ""
        return name.isEmpty ? ProcessInfo.processInfo.hostName : name
    }

    var onState: ((Bool, String) -> Void)?
    var onAccepted: ((Accepted) -> Void)?

    private let queue = DispatchQueue(label: "remotely.listener")
    private var listener: NWListener?
    private var handshakes: [ObjectIdentifier: Handshake] = [:]

    func start() {
        queue.async { self.startListener() }
    }

    private var service: NWListener.Service {
        var txt = NWTXTRecord()
        txt["id"] = Self.installID
        txt["pv"] = String(WireProtocol.version)
        txt["name"] = Self.computerName
        return NWListener.Service(name: Self.computerName, type: Self.serviceType,
                                  domain: nil, txtRecord: txt)
    }

    private func startListener() {
        do {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let params = NWParameters(tls: nil, tcp: tcp)
            params.allowLocalEndpointReuse = true
            params.serviceClass = .interactiveVideo
            listener = try NWListener(using: params,
                                      on: NWEndpoint.Port(rawValue: Self.port)!)
        } catch {
            report(false, "Could not listen on port \(Self.port): \(error.localizedDescription)")
            queue.asyncAfter(deadline: .now() + 3) { self.restartListener() }
            return
        }
        listener?.service = service
        listener?.newConnectionHandler = { [weak self] conn in
            self?.beginHandshake(conn)
        }
        listener?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.report(true, "Waiting for devices on port \(Self.port)")
            case .failed(let error):
                Log.info("listener failed: \(error), restarting in 1s")
                self.report(false, "Listener failed, restarting…")
                self.queue.asyncAfter(deadline: .now() + 1) { self.restartListener() }
            case .cancelled:
                self.report(false, "Not listening")
            default:
                break
            }
        }
        listener?.start(queue: queue)
    }

    private func restartListener() {
        listener?.cancel()
        listener = nil
        startListener()
    }

    private func report(_ listening: Bool, _ text: String) {
        Log.info("listener: \(text)")
        onState?(listening, text)
    }

    private func beginHandshake(_ conn: NWConnection) {
        Log.info("incoming connection from \(String(describing: conn.endpoint))")
        let handshake = Handshake(connection: conn, queue: queue) { [weak self] hello in
            guard let self else { return }
            self.handshakes[ObjectIdentifier(conn)] = nil
            guard let hello else { return }
            Log.info("hello accepted: \(hello.kind) \(hello.pixelsWide)x\(hello.pixelsHigh)"
                     + " id \(hello.id ?? "none")")
            self.onAccepted?(Accepted(connection: conn, hello: hello))
        }
        handshakes[ObjectIdentifier(conn)] = handshake
        handshake.start()
    }
}

private final class Handshake {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let completion: (PhoneInfo?) -> Void
    private var finished = false
    private let deadline: TimeInterval = 10

    init(connection: NWConnection, queue: DispatchQueue,
         completion: @escaping (PhoneInfo?) -> Void) {
        self.connection = connection
        self.queue = queue
        self.completion = completion
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.readHeader()
            case .failed, .cancelled: self.finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + deadline) { [weak self] in
            guard let self, !self.finished else { return }
            Log.info("handshake timed out, dropping the connection")
            self.finish(nil)
        }
    }

    private func readHeader() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) {
            [weak self] header, _, _, error in
            guard let self, !self.finished else { return }
            guard error == nil, let header, header.count == 4 else {
                self.finish(nil)
                return
            }
            let len = Int(UInt32(bigEndian: header.withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self)
            }))
            guard len > 0, len < 1 << 20 else {
                self.finish(nil)
                return
            }
            self.readPayload(length: len)
        }
    }

    private func readPayload(length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) {
            [weak self] payload, _, _, error in
            guard let self, !self.finished else { return }
            guard error == nil, let payload, payload.count == length,
                  let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  obj["type"] as? String == "hello",
                  let hello = try? JSONDecoder().decode(PhoneInfo.self, from: payload),
                  hello.isUsablePanel else {
                Log.info("first message was not a usable hello, dropping the connection")
                self.finish(nil)
                return
            }
            self.finish(hello)
        }
    }

    private func finish(_ hello: PhoneInfo?) {
        guard !finished else { return }
        finished = true
        if hello == nil { connection.cancel() }
        completion(hello)
    }
}

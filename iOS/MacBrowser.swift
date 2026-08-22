import Foundation
import Network

struct DiscoveredMac: Identifiable, Equatable {
    let id: String
    let name: String
    let endpoint: NWEndpoint

    static func == (lhs: DiscoveredMac, rhs: DiscoveredMac) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name
    }
}

final class MacBrowser: ObservableObject {
    @Published private(set) var macs: [DiscoveredMac] = []
    @Published private(set) var searching = false

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "remotely.browser")

    func start() {
        queue.async {
            guard self.browser == nil else { return }
            let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
                type: PhoneReceiver.serviceType, domain: nil)
            let browser = NWBrowser(for: descriptor, using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.publish(results)
            }
            browser.stateUpdateHandler = { [weak self, weak browser] state in
                guard let self, let browser, self.browser === browser else { return }
                switch state {
                case .ready:
                    self.setSearching(true)
                case .failed(let error):
                    Log.info("browser failed: \(error), restarting in 1s")
                    self.setSearching(false)
                    self.queue.asyncAfter(deadline: .now() + 1) { self.restart() }
                case .cancelled:
                    self.setSearching(false)
                default:
                    break
                }
            }
            self.browser = browser
            browser.start(queue: self.queue)
        }
    }

    func stop() {
        queue.async {
            self.browser?.cancel()
            self.browser = nil
            self.setSearching(false)
        }
    }

    private func restart() {
        browser?.cancel()
        browser = nil
        start()
    }

    private func publish(_ results: Set<NWBrowser.Result>) {
        let found = results.compactMap { Self.mac(from: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        DispatchQueue.main.async { self.macs = found }
    }

    private func setSearching(_ value: Bool) {
        DispatchQueue.main.async { self.searching = value }
    }

    private static func mac(from result: NWBrowser.Result) -> DiscoveredMac? {
        guard case .service(let serviceName, _, _, _) = result.endpoint else { return nil }
        var txtName: String?
        var installID: String?
        if case .bonjour(let txt) = result.metadata {
            txtName = txt["name"]
            installID = txt["id"]
        }
        let name = (txtName?.isEmpty == false) ? txtName! : serviceName
        return DiscoveredMac(id: installID ?? "service:\(serviceName)",
                             name: name, endpoint: result.endpoint)
    }
}

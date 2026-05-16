//
//  BonjourBrowser.swift
//  Sharilka_iOS
//
//  Discovers Sharilka receivers on the local network using NWBrowser.
//  Parses TXT records for protocol, app, platform, and port fields.
//

import Combine
import Foundation
import Network

@MainActor
final class BonjourBrowser: ObservableObject {
    @Published private(set) var receivers: [DiscoveredReceiver] = []
    @Published private(set) var isBrowsing = false

    private var browser: NWBrowser?
    private let serviceType = SharilkaProtocol.bonjourServiceType

    var onLog: (@MainActor (String, Bool) -> Void)?

    func startBrowsing() {
        stopBrowsing()

        let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: nil)
        let params = NWParameters()
        params.includePeerToPeer = true

        let newBrowser = NWBrowser(for: descriptor, using: params)

        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleStateChange(state)
            }
        }

        newBrowser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor [weak self] in
                self?.handleResultsChanged(results: results, changes: changes)
            }
        }

        browser = newBrowser
        newBrowser.start(queue: .main)
        isBrowsing = true
        onLog?("Started browsing for \(serviceType)", false)
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        if isBrowsing {
            isBrowsing = false
            onLog?("Stopped browsing", false)
        }
    }

    private func handleStateChange(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            onLog?("Browser ready — scanning for receivers", false)
        case .failed(let error):
            onLog?("Browser failed: \(error.localizedDescription)", true)
            isBrowsing = false
        case .cancelled:
            isBrowsing = false
        case .waiting(let error):
            onLog?("Browser waiting: \(error.localizedDescription)", false)
        default:
            break
        }
    }

    private func handleResultsChanged(results: Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            switch change {
            case .added(let result):
                let receiver = makeReceiver(from: result)
                if !receivers.contains(where: { $0.id == receiver.id }) {
                    receivers.append(receiver)
                    onLog?("Found receiver: \(receiver.name)", false)
                }
            case .removed(let result):
                let rid = endpointID(result.endpoint)
                if let idx = receivers.firstIndex(where: { $0.id == rid }) {
                    let name = receivers[idx].name
                    receivers.remove(at: idx)
                    onLog?("Receiver removed: \(name)", false)
                }
            case .changed(old: _, new: let newResult, flags: _):
                let receiver = makeReceiver(from: newResult)
                if let idx = receivers.firstIndex(where: { $0.id == receiver.id }) {
                    receivers[idx] = receiver
                }
            default:
                break
            }
        }
    }

    private nonisolated func makeReceiver(from result: NWBrowser.Result) -> DiscoveredReceiver {
        let name: String
        switch result.endpoint {
        case .service(let svcName, _, _, _):
            name = svcName
        default:
            name = "\(result.endpoint)"
        }

        var txtFields: [String: String] = [:]
        if case .bonjour(let txtRecord) = result.metadata {
            for key in ["protocol", "app", "platform", "port"] {
                if let value = txtRecord[key] {
                    txtFields[key] = value
                }
            }
        }

        return DiscoveredReceiver(
            id: endpointID(result.endpoint),
            name: name,
            endpoint: result.endpoint,
            txtFields: txtFields
        )
    }

    private nonisolated func endpointID(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .service(let name, let type, let domain, _):
            return "\(name).\(type).\(domain)"
        default:
            return "\(endpoint)"
        }
    }
}

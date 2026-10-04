//
// DroidDeck for iOS
// Copyright (C) 2026 DroidDeck-iOS contributors
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import Foundation
import Network

/// A GameStream host discovered on the local network (Sunshine or
/// GeForce Experience / NVIDIA GameStream).
struct MoonlightHost: Identifiable, Equatable {
    let name: String
    let endpoint: NWEndpoint

    var id: String {
        if case .hostPort(let host, let port) = endpoint {
            return "\(host)-\(port)"
        }
        return name
    }

    var displayAddress: String {
        if case .hostPort(let host, _) = endpoint {
            return "\(host)"
        }
        return "unknown"
    }
}

/// Browses the local network for _nvstream._tcp GameStream hosts.
///
/// M4 note: discovery/pairing/session-launch ultimately run through the
/// vendored moonlight-common-c core (see Streaming/README.md). This browser
/// feeds the UI with candidate hosts; the handshake itself is performed by
/// the C core once it is wired into the target.
@MainActor
final class MoonlightDiscovery: ObservableObject {
    @Published private(set) var hosts: [MoonlightHost] = []
    @Published private(set) var isBrowsing = false

    private var browser: NWBrowser?

    func start() {
        stop()
        hosts.removeAll()
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_nvstream._tcp", domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [MoonlightHost] = results.compactMap { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return MoonlightHost(name: name, endpoint: result.endpoint)
            }
            Task { @MainActor in
                self?.hosts = found
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isBrowsing = true
                case .failed, .cancelled:
                    self?.isBrowsing = false
                default:
                    break
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
        isBrowsing = true
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
    }
}

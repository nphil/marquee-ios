import Foundation
import LumaRemoteCore
import Network

/// A home proof requires both the paired TV's key and a direct connection over the selected Wi-Fi interface.
enum HomePresenceProbe {
    static func check(tv: PairedTV, interface: NWInterface, phone: PhoneInfo) async -> Bool {
        var addresses: [TVAddress] = [.host(tv.host, port: tv.port)]
        if let service = tv.service { addresses.append(.service(name: service)) }
        for address in addresses {
            guard !Task.isCancelled else { return false }
            if await check(address: address, tv: tv, interface: interface, phone: phone) { return true }
        }
        return false
    }

    private static func check(address: TVAddress, tv: PairedTV, interface: NWInterface, phone: PhoneInfo) async -> Bool {
        guard let stream = try? await TCPStream.connect(to: address, timeout: .seconds(3), requiredInterface: interface) else { return false }
        defer { stream.abort() }
        guard let path = stream.connectionPath, path.usesWiFi, !path.usesOther,
              NetworkPath.isDirectWiFi(local: path.localAddress, remote: path.remoteAddress, interface: interface.name)
        else { return false }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            stream.abort()
        }
        defer { deadline.cancel() }
        return await withTaskCancellationHandler {
            do {
                let channel = try await SecureChannel.open(stream, mode: .session, psk: tv.key)
                try channel.send(.hello(phone, kit: "LumaRemoteKit \(LumaRemote.version)"))
                let message: ServerMessage = try await channel.receive()
                guard case .welcome(let welcome) = message else { return false }
                return !Task.isCancelled && welcome.tv.id == tv.id
            } catch {
                return false
            }
        } onCancel: {
            stream.abort()
        }
    }
}

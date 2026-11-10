import Foundation
import LumaRemoteCore
import Network

/// A home proof requires both the paired TV's key and a direct connection over the selected Wi-Fi interface.
enum HomePresenceProbe {
    /// Whether a connection to the TV on `path` runs directly over `interface`.
    static func isDirect(_ path: ConnectionPath, over interface: NWInterface) -> Bool {
        path.usesWiFi && !path.usesOther
            && NetworkPath.isDirectWiFi(local: path.localAddress, remote: path.remoteAddress, interface: interface.name)
    }

    static func check(tv: PairedTV, interface: NWInterface) async -> Bool {
        var addresses: [TVAddress] = [.host(tv.host, port: tv.port)]
        if let service = tv.service { addresses.append(.service(name: service)) }
        for address in addresses {
            guard !Task.isCancelled else { return false }
            if await check(address: address, tv: tv, interface: interface) { return true }
        }
        return false
    }

    private static func check(address: TVAddress, tv: PairedTV, interface: NWInterface) async -> Bool {
        guard let stream = try? await TCPStream.connect(to: address, timeout: .seconds(3), requiredInterface: interface) else { return false }
        defer { stream.abort() }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            stream.abort()
        }
        defer { deadline.cancel() }
        return await withTaskCancellationHandler {
            do {
                // Only the TV holding this pairing's key completes the handshake. No hello follows: the TV
                // gives a phone one session, so a hello here would end the remote's own.
                _ = try await SecureChannel.open(stream, mode: .session, psk: tv.key)
                // The path is judged after the handshake, not before it: the TV counts a connection closed
                // ahead of the handshake as a failed one, and 8 of them in 60 s make it ignore this phone,
                // the remote's own session included.
                guard !Task.isCancelled, let path = stream.connectionPath else { return false }
                return isDirect(path, over: interface)
            } catch {
                return false
            }
        } onCancel: {
            stream.abort()
        }
    }
}

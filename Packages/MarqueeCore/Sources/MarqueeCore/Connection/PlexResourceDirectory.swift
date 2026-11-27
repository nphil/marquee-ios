import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

#if canImport(Darwin) || canImport(FoundationXML)
/// The authenticated /api/resources directory returns Device entries and their Connection children.
final class PlexResourceDirectory: NSObject, XMLParserDelegate {
    private var root: String?
    private var depth = 0
    private var current: PlexServer?
    private var servers: [PlexServer] = []

    static func decode(_ data: Data) throws -> [PlexServer] {
        let directory = PlexResourceDirectory()
        let parser = XMLParser(data: data)
        parser.delegate = directory
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), parser.parserError == nil, directory.root == "MediaContainer" else {
            throw PlexError.decoding("invalid Plex server directory")
        }
        return directory.servers
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        depth += 1
        if depth == 1 { root = element; return }
        func flag(_ key: String) -> Bool { a[key] == "1" || a[key]?.lowercased() == "true" }
        if depth == 2, element == "Device", let id = a["clientIdentifier"], !id.isEmpty,
           a["provides"]?.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "server" }) == true {
            current = PlexServer(name: a["name"] ?? id, clientIdentifier: id, accessToken: a["accessToken"], isOwned: flag("owned"),
                                 isHome: flag("home"), ownerName: a["sourceTitle"], isPresent: flag("presence"), httpsRequired: flag("httpsRequired"),
                                 productVersion: a["productVersion"], connections: [])
        } else if depth == 3, element == "Connection", current != nil, let value = a["uri"], let url = URL(string: value),
                  ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil, url.user == nil, url.password == nil {
            current?.connections.append(PlexConnection(uri: url, isLocal: flag("local"), isRelay: flag("relay"), isIPv6: flag("IPv6")))
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if depth == 2, element == "Device", let current { servers.append(current); self.current = nil }
        depth -= 1
    }
}
#endif

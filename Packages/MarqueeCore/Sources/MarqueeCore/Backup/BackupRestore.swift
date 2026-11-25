import Foundation

/// A device's settings as a backup sees them. The platform supplies this over its own storage; the rules for
/// what is read, what is written and how a failure is undone live here, where they are tested.
public protocol BackupStore {
    /// Everything on the device that the scope covers, classified.
    func read() throws -> [BackupEntry]
    /// Throws for an entry the device cannot take, before anything is written.
    func validate(_ entry: BackupEntry) throws
    func write(_ entry: BackupEntry) throws
    func remove(_ entry: BackupEntry) throws
}

extension BackupStore {
    public func validate(_ entry: BackupEntry) throws {}
}

public enum BackupRestore {
    public struct Plan: Equatable, Sendable {
        public var entries: [BackupEntry]
        /// A backup from this platform replaces everything in scope, so what it lacks is removed too. One from
        /// the other platform only sets the integrations it has.
        public var replacesAll: Bool
    }

    /// What restoring `payload` on the iPhone writes.
    public static func plan(_ payload: BackupPayload, scope: BackupScope = .phone) -> Plan {
        if payload.platform == BackupPlatform.ios {
            return Plan(entries: payload.entries.filter(scope.covers), replacesAll: true)
        }
        return Plan(entries: BackupScope.phoneEntries(from: payload.integrations).filter(scope.covers), replacesAll: false)
    }

    /// Applies `plan` all or nothing: every entry is checked first, then written (secrets before the rest, so a
    /// locked Keychain stops it before anything else changed) and, if anything fails, every change is undone
    /// from a copy taken before the first write.
    public static func apply(_ plan: Plan, to store: some BackupStore, scope: BackupScope = .phone) throws {
        var wanted: [String: BackupEntry] = [:]
        for entry in plan.entries where scope.covers(entry) { wanted[entry.id] = entry }
        for entry in wanted.values {
            do { try store.validate(entry) } catch { throw BackupError.restoreFailed }
        }

        let before: [String: BackupEntry]
        do {
            before = Dictionary(try store.read().map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        } catch {
            throw BackupError.restoreFailed
        }

        let writes = wanted.values.filter { before[$0.id]?.value != $0.value }.sorted { lhs, rhs in
            (lhs.store == BackupScope.Phone.secret ? 0 : 1, lhs.id) < (rhs.store == BackupScope.Phone.secret ? 0 : 1, rhs.id)
        }
        let removals = plan.replacesAll ? before.values.filter { wanted[$0.id] == nil }.sorted { $0.id < $1.id } : []

        // An entry joins the undo list before its own write, so one that fails half way is put back too.
        var touched: [String] = []
        do {
            for entry in writes {
                touched.append(entry.id)
                try store.write(entry)
            }
            for entry in removals {
                touched.append(entry.id)
                try store.remove(entry)
            }
        } catch {
            var undone = true
            for id in touched.reversed() {
                do {
                    if let old = before[id] { try store.write(old) } else if let new = wanted[id] { try store.remove(new) }
                } catch {
                    undone = false
                }
            }
            throw undone ? BackupError.restoreFailed : BackupError.restoreIncomplete
        }
    }
}

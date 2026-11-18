import AVFoundation
import MarqueeCore
import MetricKit
import Network
import os
import UIKit

/// The phone around the app, in the diagnostic log (DESIGN §8.12): how the launch found it, then memory,
/// heat, power, VoiceOver, the network path, the audio route and other scenes as they change, and
/// MetricKit's crash, hang and resource reports on earlier runs once iOS hands them over. It also keeps the
/// journal's marker of where the app stands, and sends the live log as the app goes to the background.
@MainActor
final class SystemMonitor {
    static let shared = SystemMonitor()

    /// The network path as last seen, for a report.
    private(set) var network = "unknown"
    private var observers: [any NSObjectProtocol] = []
    private var memoryTask: Task<Void, Never>?
    private var lastFootprint: Int64 = 0
    private let pathMonitor = NWPathMonitor()
    private let metrics = MetricsReceiver()
    private var started = false
    private var scenes: [ObjectIdentifier: String] = [:]
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var backgroundGeneration = 0

    func start() {
        guard !started else { return }
        started = true
        logLaunch()
        observeApp()
        observeSystem()
        observeAudio()
        watchPath()
        watchMemory()
        MXMetricManager.shared.add(metrics)
    }

    /// The phone line of a report.
    var summary: String {
        let process = ProcessInfo.processInfo
        return [
            Self.model, "iOS \(UIDevice.current.systemVersion)", Locale.current.identifier, TimeZone.current.identifier,
            Self.freeSpace().map { "\($0.formatted(.byteCount(style: .file))) free" } ?? "free space unknown",
            "thermal \(Self.word(process.thermalState))", process.isLowPowerModeEnabled ? "Low Power on" : "Low Power off",
            PlayerStats.footprint().map { "\($0.formatted(.byteCount(style: .memory))) used" } ?? "memory unknown",
        ].joined(separator: " · ")
    }

    private func logLaunch() {
        let process = ProcessInfo.processInfo
        Diag.event(.app, "launch", [
            "version": AppBuild.version, "build": AppBuild.build, "commit": AppBuild.commit, "launch": DiagLog.shared.launch,
            "ios": UIDevice.current.systemVersion, "model": Self.model, "locale": Locale.current.identifier,
            "tz": TimeZone.current.identifier, "freeGB": Self.freeSpace().map { Double($0) / 1e9 },
            "lowPower": process.isLowPowerModeEnabled, "thermal": Self.word(process.thermalState),
            "voiceOver": UIAccessibility.isVoiceOverRunning, "reduceMotion": UIAccessibility.isReduceMotionEnabled,
            "boldText": UIAccessibility.isBoldTextEnabled, "darkerColors": UIAccessibility.isDarkerSystemColorsEnabled,
            "reduceTransparency": UIAccessibility.isReduceTransparencyEnabled,
            "memoryMB": PlayerStats.footprint().map { $0 >> 20 }, "uiTest": FakePlex.isActive,
        ], .notice)
    }

    /// The marker the next launch reads, and the live log sent before iOS suspends the app.
    private func observeApp() {
        on(UIApplication.didFinishLaunchingNotification) {
            if UIApplication.shared.applicationState == .background {
                DiagLog.shared.setPhase(.background)
                Diag.event(.app, "launched.background")
            }
        }
        on(UIApplication.didBecomeActiveNotification) { DiagLog.shared.setPhase(.foreground) }
        on(UIApplication.didEnterBackgroundNotification) { [weak self] in
            DiagLog.shared.setPhase(.background)
            self?.flushInBackground()
        }
        on(UIApplication.willTerminateNotification) {
            Diag.event(.app, "terminate")
            DiagLog.shared.end()
        }
        on(UIApplication.didReceiveMemoryWarningNotification) {
            Diag.event(.app, "memory.warning", [
                "footprintMB": PlayerStats.footprint().map { $0 >> 20 }, "availableMB": Int64(os_proc_available_memory()) >> 20,
            ], .warning)
        }
    }

    private func observeSystem() {
        on(ProcessInfo.thermalStateDidChangeNotification) {
            let state = ProcessInfo.processInfo.thermalState
            Diag.event(.app, "thermal", ["state": Self.word(state)], state.rawValue >= ProcessInfo.ThermalState.serious.rawValue ? .notice : .info)
        }
        on(Notification.Name.NSProcessInfoPowerStateDidChange) {
            Diag.event(.app, "low-power", ["on": ProcessInfo.processInfo.isLowPowerModeEnabled])
        }
        on(UIAccessibility.voiceOverStatusDidChangeNotification) {
            Diag.event(.app, "voiceover", ["on": UIAccessibility.isVoiceOverRunning])
        }
        on(UIScene.willConnectNotification) { [weak self] in self?.scenesChanged() }
        on(UIScene.didDisconnectNotification) { [weak self] in self?.scenesChanged() }
    }

    /// The phone's scene, and glasses or a TV as they connect and leave, by role.
    private func scenesChanged() {
        var now: [ObjectIdentifier: String] = [:]
        for scene in UIApplication.shared.connectedScenes {
            now[ObjectIdentifier(scene)] = scene.session.role.rawValue
        }
        for (id, role) in now where scenes[id] == nil {
            Diag.event(.bigscreen, "scene.connect", ["role": role, "scenes": now.count])
        }
        for (id, role) in scenes where now[id] == nil {
            Diag.event(.bigscreen, "scene.disconnect", ["role": role, "scenes": now.count])
        }
        scenes = now
    }

    private func observeAudio() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
            let session = AVAudioSession.sharedInstance()
            Diag.event(.audio, "route", [
                "reason": reason.map(Self.word) ?? "unknown", "outputs": Self.outputs(session), "channels": session.outputNumberOfChannels,
                "maxChannels": session.maximumOutputNumberOfChannels, "rendering": Self.word(session.renderingMode),
                "category": session.category.rawValue,
            ])
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
            let reason = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            Diag.event(.audio, "interruption", [
                "phase": type == .began ? "began" : "ended", "resume": options.contains(.shouldResume), "reason": reason,
            ], .notice)
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            Diag.event(.audio, "media-services.reset", [:], .warning)
        })
        observers.append(center.addObserver(forName: AVAudioSession.renderingModeChangeNotification, object: nil, queue: .main) { _ in
            Diag.event(.audio, "rendering", ["mode": Self.word(AVAudioSession.sharedInstance().renderingMode)])
        })
    }

    private func on(_ name: Notification.Name, _ handle: @escaping @MainActor @Sendable () -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handle() }
        })
    }

    private func watchPath() {
        pathMonitor.pathUpdateHandler = { path in
            let summary = Self.describe(path)
            Task { @MainActor in SystemMonitor.shared.pathChanged(summary) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.nphil.marquee.diagnostics.path", qos: .utility))
    }

    private func pathChanged(_ summary: PathSummary) {
        let text = summary.text
        guard text != network else { return }
        network = text
        Diag.event(.net, "path", [
            "status": summary.status, "interfaces": summary.interfaces, "expensive": summary.expensive,
            "constrained": summary.constrained, "reason": summary.reason,
        ], summary.status == "satisfied" ? .info : .notice)
    }

    /// Every 30 s, a line when the footprint moved by 32 MB or more since the last one.
    private func watchMemory() {
        memoryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                guard let footprint = PlayerStats.footprint(), abs(footprint - lastFootprint) >= 32 << 20 else { continue }
                lastFootprint = footprint
                Diag.event(.app, "memory", [
                    "footprintMB": footprint >> 20, "availableMB": Int64(os_proc_available_memory()) >> 20,
                ])
            }
        }
    }

    /// Sends what waits before iOS suspends the app, inside the time a background task allows.
    private func flushInBackground() {
        endBackgroundTask()
        backgroundGeneration += 1
        let generation = backgroundGeneration
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "marquee-diagnostics") { [weak self] in
            // iOS ends the app unless the assertion ends before this handler returns.
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
        DiagLog.shared.flushLive {
            Task { @MainActor in SystemMonitor.shared.endBackgroundTask(generation) }
        }
    }

    /// Ends the assertion; a flush that finishes after a later trip to the background leaves that one's alone.
    private func endBackgroundTask(_ generation: Int? = nil) {
        guard backgroundTask != .invalid, generation == nil || generation == backgroundGeneration else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: Words

    private struct PathSummary: Sendable {
        var status: String
        var interfaces: String
        var expensive: Bool
        var constrained: Bool
        var reason: String?

        var text: String {
            "\(status) \(interfaces)\(expensive ? " · expensive" : "")\(constrained ? " · constrained" : "")"
        }
    }

    private nonisolated static func describe(_ path: NWPath) -> PathSummary {
        let status = switch path.status {
        case .satisfied: "satisfied"
        case .unsatisfied: "unsatisfied"
        case .requiresConnection: "requires-connection"
        @unknown default: "unknown"
        }
        let interfaces = path.availableInterfaces.map { "\($0.type)" }
        var reason: String?
        if path.status == .unsatisfied {
            reason = switch path.unsatisfiedReason {
            case .notAvailable: "not-available"
            case .cellularDenied: "cellular-denied"
            case .wifiDenied: "wifi-denied"
            case .localNetworkDenied: "local-network-denied"
            @unknown default: "unknown"
            }
        }
        return PathSummary(
            status: status, interfaces: interfaces.isEmpty ? "none" : interfaces.joined(separator: ","),
            expensive: path.isExpensive, constrained: path.isConstrained, reason: reason
        )
    }

    /// `HDMI:6ch,Speaker:2ch`: each output's port type and channels.
    nonisolated static func outputs(_ session: AVAudioSession) -> String {
        let outputs = session.currentRoute.outputs.map { port in
            port.portType.rawValue + (port.channels.map { ":\($0.count)ch" } ?? "")
        }
        return outputs.isEmpty ? "none" : outputs.joined(separator: ",")
    }

    nonisolated static func word(_ mode: AVAudioSession.RenderingMode) -> String {
        switch mode {
        case .notApplicable: "n/a"
        case .monoStereo: "stereo"
        case .surround: "surround"
        case .spatialAudio: "spatial"
        case .dolbyAudio: "dolby"
        case .dolbyAtmos: "atmos"
        @unknown default: "unknown"
        }
    }

    nonisolated static func word(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .newDeviceAvailable: "new-device"
        case .oldDeviceUnavailable: "device-gone"
        case .categoryChange: "category"
        case .override: "override"
        case .wakeFromSleep: "wake"
        case .noSuitableRouteForCategory: "no-route"
        case .routeConfigurationChange: "configuration"
        case .unknown: "unknown"
        @unknown default: "unknown"
        }
    }

    nonisolated static func word(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    /// `iPhone17,1`, or the simulated model's.
    private static let model: String = {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }()

    private static func freeSpace() -> Int64? {
        let values = try? URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// MetricKit hands over the earlier runs' crash, hang, CPU and disk-write reports some time after a launch;
/// each becomes a line with the first frames of the thread it blames, as `binary+offset` for the build's dSYM.
private final class MetricsReceiver: NSObject, MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                Diag.event(.app, "metrickit.crash", [
                    "version": crash.applicationVersion, "build": crash.metaData.applicationBuildVersion,
                    "os": crash.metaData.osVersion, "exception": crash.exceptionType, "code": crash.exceptionCode,
                    "signal": crash.signal, "reason": crash.terminationReason, "objc": crash.exceptionReason?.composedMessage,
                    "at": payload.timeStampEnd, "frames": Self.frames(crash.callStackTree),
                ], .warning)
            }
            for hang in payload.hangDiagnostics ?? [] {
                Diag.event(.app, "metrickit.hang", [
                    "version": hang.applicationVersion, "seconds": hang.hangDuration.converted(to: .seconds).value,
                    "at": payload.timeStampEnd, "frames": Self.frames(hang.callStackTree),
                ], .warning)
            }
            for cpu in payload.cpuExceptionDiagnostics ?? [] {
                Diag.event(.app, "metrickit.cpu", [
                    "version": cpu.applicationVersion, "cpuSeconds": cpu.totalCPUTime.converted(to: .seconds).value,
                    "sampledSeconds": cpu.totalSampledTime.converted(to: .seconds).value,
                    "at": payload.timeStampEnd, "frames": Self.frames(cpu.callStackTree),
                ], .notice)
            }
            for disk in payload.diskWriteExceptionDiagnostics ?? [] {
                Diag.event(.app, "metrickit.disk-writes", [
                    "version": disk.applicationVersion, "mb": disk.totalWritesCaused.converted(to: .megabytes).value,
                    "at": payload.timeStampEnd, "frames": Self.frames(disk.callStackTree),
                ], .notice)
            }
        }
    }

    private static func frames(_ tree: MXCallStackTree) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: tree.jsonRepresentation()) as? [String: Any],
              let stacks = object["callStacks"] as? [[String: Any]] else { return "-" }
        let stack = stacks.first { $0["threadAttributed"] as? Bool == true } ?? stacks.first
        var frames: [String] = []
        var level = stack?["callStackRootFrames"] as? [[String: Any]]
        while let frame = level?.first, frames.count < 10 {
            let binary = frame["binaryName"] as? String ?? "?"
            let offset = frame["offsetIntoBinaryTextSegment"] as? Int ?? 0
            frames.append("\(binary)+0x\(String(offset, radix: 16))")
            level = frame["subFrames"] as? [[String: Any]]
        }
        return frames.joined(separator: " ")
    }
}

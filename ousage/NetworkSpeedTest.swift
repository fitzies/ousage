//
//  NetworkSpeedTest.swift
//  ousage
//

import Combine
import Foundation
import Network

nonisolated struct SpeedTestResult: Codable, Sendable {
    /// Bits per second.
    let download: Double
    let upload: Double
    let testedAt: Date
}

nonisolated enum SpeedTestInterval: Int, CaseIterable, Codable, Identifiable, Sendable {
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case hour = 60
    case threeHours = 180
    case sixHours = 360
    case manual = 0

    var id: Int { rawValue }

    var seconds: TimeInterval? {
        self == .manual ? nil : TimeInterval(rawValue * 60)
    }

    var title: String {
        switch self {
        case .fifteenMinutes: "15 minutes"
        case .thirtyMinutes: "30 minutes"
        case .hour: "Hour"
        case .threeHours: "3 hours"
        case .sixHours: "6 hours"
        case .manual: "Only when asked"
        }
    }
}

/// Runs macOS's built-in `networkQuality` test against Apple's servers on a schedule.
@MainActor
final class NetworkSpeedTest: ObservableObject {
    @Published private(set) var result: SpeedTestResult?
    @Published private(set) var isRunning = false
    @Published private(set) var message: String?

    private var interval: TimeInterval?
    private var schedulingTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private var isMetered = false

    private static let resultKey = "speedTest.lastResult"

    init() {
        result = UserDefaults.standard.data(forKey: Self.resultKey)
            .flatMap { try? JSONDecoder().decode(SpeedTestResult.self, from: $0) }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let isMetered = path.isExpensive || path.isConstrained
            Task { @MainActor in self?.isMetered = isMetered }
        }
        pathMonitor.start(queue: .main)
    }

    /// `nil` stops scheduled tests; a stale result is retested shortly after this is set.
    func setInterval(_ seconds: TimeInterval?) {
        guard seconds != interval || (seconds != nil && schedulingTask == nil) else { return }
        interval = seconds
        schedulingTask?.cancel()
        schedulingTask = nil

        guard seconds != nil else { return }
        schedulingTask = Task { [weak self] in
            // Let launch settle before saturating the connection.
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                guard let self else { return }
                await self.runIfDue()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func runNow() {
        Task { [weak self] in
            await self?.run()
        }
    }

    private func runIfDue() async {
        guard let interval, !isMetered else { return }
        let lastTest = result?.testedAt ?? .distantPast
        guard Date().timeIntervalSince(lastTest) >= interval else { return }
        await run()
    }

    private func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        do {
            let newResult = try await NetworkQualityRunner.run()
            result = newResult
            message = nil
            if let data = try? JSONEncoder().encode(newResult) {
                UserDefaults.standard.set(data, forKey: Self.resultKey)
            }
        } catch {
            message = error.localizedDescription
        }
    }
}

private nonisolated enum NetworkQualityRunner {
    /// Sequential download then upload, like speedtest sites, capped so a slow link can't run on.
    static func run() async throws -> SpeedTestResult {
        let output = try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
            process.arguments = ["-c", "-s", "-M", "20"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data
        }.value

        guard let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              let download = (object["dl_throughput"] as? NSNumber)?.doubleValue,
              let upload = (object["ul_throughput"] as? NSNumber)?.doubleValue,
              download > 0 || upload > 0 else {
            throw SpeedTestError.failed
        }

        return SpeedTestResult(download: download, upload: upload, testedAt: Date())
    }
}

private enum SpeedTestError: LocalizedError {
    case failed

    var errorDescription: String? {
        "The speed test couldn’t reach Apple’s test servers."
    }
}

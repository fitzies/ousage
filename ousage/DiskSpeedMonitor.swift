//
//  DiskSpeedMonitor.swift
//  ousage
//

import Combine
import Foundation
import IOKit

nonisolated struct SpeedSample: Sendable, Equatable {
    let inbound: Double   // bytes per second read
    let outbound: Double  // bytes per second written
}

@MainActor
final class DiskSpeedMonitor: ObservableObject {
    @Published private(set) var disk: SpeedSample?

    private var diskActive = false
    private var previousDisk: CounterReading<UInt64>?
    private var samplingTask: Task<Void, Never>?

    /// Sampling only runs while at least one consumer wants it. Call with the current needs whenever they change; idempotent.
    func setActive(disk wantsDisk: Bool) {
        if wantsDisk != diskActive {
            diskActive = wantsDisk
            previousDisk = wantsDisk ? SystemCounters.readDisk() : nil
            if disk != nil { disk = nil }
        }

        if diskActive {
            startSampling()
        } else {
            stopSampling()
        }
    }

    private func startSampling() {
        guard samplingTask == nil else { return }

        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    private func stopSampling() {
        samplingTask?.cancel()
        samplingTask = nil
    }

    private func tick() {
        let reading = SystemCounters.readDisk()
        if let previous = previousDisk, let sample = reading.rate(since: previous), sample != disk {
            disk = sample
        }
        previousDisk = reading
    }
}

extension SpeedSample {
    /// Network style, e.g. "0.9 Gbps", "42 Mbps", "850 Kbps", "0 Kbps"
    nonisolated static func formatBits(_ bitsPerSecond: Double) -> String {
        format(bitsPerSecond, units: ["Kbps", "Mbps", "Gbps"])
    }

    /// Disk style, bytes per second, e.g. "1.2 GB/s", "300 MB/s", "12 KB/s", "0 KB/s"
    nonisolated static func formatBytes(_ bytesPerSecond: Double) -> String {
        format(bytesPerSecond, units: ["KB/s", "MB/s", "GB/s"])
    }

    private nonisolated static func format(_ base: Double, units: [String]) -> String {
        guard base.isFinite else { return "0 \(units[0])" }

        var value = max(0, base) / 1000
        var index = 0
        // 999.5 would round to "1000", so promote it to the next unit.
        while value >= 999.5, index < units.count - 1 {
            value /= 1000
            index += 1
        }

        if index == 0, value < 1 { return "0 \(units[0])" }
        if value >= 9.95 { return "\(Int(value.rounded())) \(units[index])" }
        return String(format: "%.1f %@", value, units[index])
    }
}

// MARK: - Counter reading

nonisolated struct ByteCounters: Sendable {
    let inbound: UInt64
    let outbound: UInt64
}

/// Cumulative byte counters per driver registry ID at a point in time.
nonisolated struct CounterReading<Key: Hashable & Sendable>: Sendable {
    let uptime: TimeInterval
    let counters: [Key: ByteCounters]

    /// Per-source deltas so a source that resets or disappears never produces a negative or bogus spike.
    func rate(since previous: CounterReading<Key>) -> SpeedSample? {
        let elapsed = uptime - previous.uptime
        guard elapsed > 0 else { return nil }

        var inbound: UInt64 = 0
        var outbound: UInt64 = 0
        for (key, current) in counters {
            guard let old = previous.counters[key] else { continue }
            if current.inbound > old.inbound { inbound &+= current.inbound - old.inbound }
            if current.outbound > old.outbound { outbound &+= current.outbound - old.outbound }
        }

        return SpeedSample(
            inbound: Double(inbound) / elapsed,
            outbound: Double(outbound) / elapsed
        )
    }
}

nonisolated enum SystemCounters {
    /// Cumulative read/write bytes per IOBlockStorageDriver.
    static func readDisk() -> CounterReading<UInt64> {
        let uptime = ProcessInfo.processInfo.systemUptime
        var counters: [UInt64: ByteCounters] = [:]

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOBlockStorageDriver"),
            &iterator
        ) == KERN_SUCCESS else {
            return CounterReading(uptime: uptime, counters: counters)
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            guard let property = IORegistryEntryCreateCFProperty(
                service,
                "Statistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue(),
                let statistics = property as? [String: Any] else { continue }

            let read = (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            let written = (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0

            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { continue }

            counters[entryID] = ByteCounters(inbound: read, outbound: written)
        }

        return CounterReading(uptime: uptime, counters: counters)
    }
}

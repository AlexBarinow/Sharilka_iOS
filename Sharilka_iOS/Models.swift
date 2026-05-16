//
//  Models.swift
//  Sharilka_iOS
//
//  Core data models for transfer state, discovered receivers, and protocol constants.
//  Protocol constants match the macOS Sharilka receiver exactly.
//

import Foundation
import Network

// MARK: - Transfer State

enum TransferState: String, Sendable {
    case idle = "Idle"
    case browsing = "Browsing"
    case ready = "Ready"
    case connecting = "Connecting"
    case sendingHeader = "Sending Header"
    case sendingFile = "Sending File"
    case completed = "Completed"
    case failed = "Failed"
    case cancelled = "Cancelled"

    var isActive: Bool {
        switch self {
        case .connecting, .sendingHeader, .sendingFile:
            return true
        default:
            return false
        }
    }
}

// MARK: - Discovered Receiver

struct DiscoveredReceiver: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
    var txtFields: [String: String] = [:]

    var displayName: String { name }

    var protocolVersion: String? { txtFields["protocol"] }
    var app: String? { txtFields["app"] }
    var platform: String? { txtFields["platform"] }
    var portString: String? { txtFields["port"] }

    var endpointDescription: String {
        switch endpoint {
        case .service(let name, let type, let domain, _):
            return "\(name).\(type)\(domain)"
        case .hostPort(let host, let port):
            return "\(host):\(port)"
        default:
            return "\(endpoint)"
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: DiscoveredReceiver, rhs: DiscoveredReceiver) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - File Info

struct FileInfo: Sendable {
    let url: URL
    let name: String
    let size: UInt64

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

// MARK: - Log Entry

struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let isError: Bool

    init(_ message: String, isError: Bool = false) {
        self.timestamp = .now
        self.message = message
        self.isError = isError
    }

    var formattedTimestamp: String {
        Self.formatter.string(from: timestamp)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

// MARK: - Protocol Constants (must match macOS Sharilka receiver)

enum SharilkaProtocol {
    static let magic: [UInt8] = [0x53, 0x48, 0x52, 0x4B] // "SHRK"
    static let version: UInt8 = 2
    /// v2 header: magic(4) + version(1) + flags(1) + filenameLen(8) + fileSize(8) = 22 bytes
    static let headerFixedSize = 4 + 1 + 1 + 8 + 8
    static let bonjourServiceType = "_sharilka._tcp"
    static let defaultChunkSize = 1_048_576 // 1 MB
}

// MARK: - Transfer Flags

struct TransferFlags: Sendable {
    static let none: UInt8 = 0
    static let benchmark: UInt8 = 1 << 0
}

// MARK: - Transfer Chunk Size Setting

enum TransferSettings {
    private static let chunkSizeKey = "sharilka_transfer_chunk_size"

    /// Available chunk sizes for manual selection.
    static let availableChunkSizes: [Int] = [
        262_144,      // 256 KB
        524_288,      // 512 KB
        1_048_576,    // 1 MB
        2_097_152,    // 2 MB
        4_194_304,    // 4 MB
        8_388_608,    // 8 MB
        16_777_216,   // 16 MB
    ]

    static var savedChunkSize: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: chunkSizeKey)
            return stored > 0 ? stored : SharilkaProtocol.defaultChunkSize
        }
        set {
            UserDefaults.standard.set(newValue, forKey: chunkSizeKey)
        }
    }

    static func formattedChunkSize(_ bytes: Int) -> String {
        if bytes >= 1_048_576 {
            let mb = Double(bytes) / 1_048_576.0
            if mb == Double(Int(mb)) {
                return "\(Int(mb)) MB"
            }
            return String(format: "%.1f MB", mb)
        } else {
            let kb = bytes / 1024
            return "\(kb) KB"
        }
    }
}

// MARK: - Benchmark Models

enum BenchmarkState: String, Sendable {
    case idle = "Idle"
    case preparing = "Preparing"
    case running = "Running"
    case completed = "Completed"
    case failed = "Failed"
    case cancelled = "Cancelled"

    var isActive: Bool {
        switch self {
        case .preparing, .running:
            return true
        default:
            return false
        }
    }
}

struct BenchmarkRunResult: Identifiable, Sendable {
    let id = UUID()
    let chunkSize: Int
    let bytesSent: UInt64
    let duration: TimeInterval
    let averageSpeedMBps: Double

    var formattedChunkSize: String {
        TransferSettings.formattedChunkSize(chunkSize)
    }

    var formattedSpeed: String {
        String(format: "%.1f MB/s", averageSpeedMBps)
    }
}

struct BenchmarkResult: Sendable {
    let runs: [BenchmarkRunResult]
    let recommendedChunkSize: Int
    let benchmarkPayloadSize: UInt64

    var recommendedRun: BenchmarkRunResult? {
        runs.first(where: { $0.chunkSize == recommendedChunkSize })
    }
}

// Chunk sizes to test during benchmark
enum BenchmarkConfig {
    static let chunkSizes: [Int] = [
        262_144,      // 256 KB
        524_288,      // 512 KB
        1_048_576,    // 1 MB
        2_097_152,    // 2 MB
        4_194_304,    // 4 MB
        8_388_608,    // 8 MB
        16_777_216,   // 16 MB
    ]
    static let defaultPayloadSize: UInt64 = 1_073_741_824 // 1 GB
    static let pauseBetweenRuns: TimeInterval = 0.75       // seconds
}

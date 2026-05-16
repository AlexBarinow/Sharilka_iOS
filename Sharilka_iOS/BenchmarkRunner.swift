//
//  BenchmarkRunner.swift
//  Sharilka_iOS
//
//  Orchestrates sequential benchmark transfers to determine the best chunk size.
//  Each benchmark run sends a limited payload (default 256 MB or file size if smaller)
//  using the full SHRK protocol, one chunk size at a time.
//

import Foundation
import Network

/// Runs sequential benchmark transfers for each configured chunk size,
/// measures throughput, and reports the best performing chunk size.
final class BenchmarkRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    private var currentSender: FileSender?

    private var isCancelled: Bool {
        get { lock.withLock { _cancelled } }
        set { lock.withLock { _cancelled = newValue } }
    }

    // Callbacks — called from background queue, caller must dispatch to @MainActor
    var onStateChange: (@Sendable (BenchmarkState) -> Void)?
    var onRunStarted: (@Sendable (Int, Int) -> Void)?       // (runIndex 0-based, chunkSize)
    var onRunProgress: (@Sendable (UInt64, UInt64) -> Void)? // (bytesSent, totalBytes)
    var onRunCompleted: (@Sendable (BenchmarkRunResult) -> Void)?
    var onBenchmarkCompleted: (@Sendable (BenchmarkResult) -> Void)?
    var onError: (@Sendable (String) -> Void)?
    var onLog: (@Sendable (String, Bool) -> Void)?

    /// Start the benchmark sequence.
    nonisolated func start(
        endpoint: NWEndpoint,
        fileURL: URL,
        originalFileName: String,
        originalFileSize: UInt64
    ) {
        isCancelled = false
        onStateChange?(.preparing)
        onLog?("📊 Benchmark started", false)

        let payloadSize = min(BenchmarkConfig.defaultPayloadSize, originalFileSize)
        let formattedPayload = ByteCountFormatter.string(fromByteCount: Int64(payloadSize), countStyle: .file)
        onLog?("Benchmark payload: \(formattedPayload) per run", false)

        let benchQueue = DispatchQueue(label: "com.sharilka.benchmark", qos: .userInitiated)
        benchQueue.async { [weak self] in
            self?.runSequentially(
                endpoint: endpoint,
                fileURL: fileURL,
                originalFileName: originalFileName,
                payloadSize: payloadSize
            )
        }
    }

    /// Cancel the current benchmark.
    nonisolated func cancel() {
        isCancelled = true
        let sender = lock.withLock { () -> FileSender? in
            let s = currentSender
            currentSender = nil
            return s
        }
        sender?.cancel()
        onLog?("📊 Benchmark cancelled", true)
        onStateChange?(.cancelled)
    }

    // MARK: - Sequential Runner

    private nonisolated func runSequentially(
        endpoint: NWEndpoint,
        fileURL: URL,
        originalFileName: String,
        payloadSize: UInt64
    ) {
        let chunkSizes = BenchmarkConfig.chunkSizes
        var results: [BenchmarkRunResult] = []

        onStateChange?(.running)

        for (index, chunkSize) in chunkSizes.enumerated() {
            guard !isCancelled else { return }

            let chunkLabel = TransferSettings.formattedChunkSize(chunkSize)
            onLog?("Testing \(chunkLabel)...", false)
            onRunStarted?(index, chunkSize)

            // Build the benchmark filename
            let chunkTag = chunkLabel.replacingOccurrences(of: " ", with: "").lowercased()
            let benchmarkFileName = "benchmark_\(chunkTag)_\(originalFileName).tmp"

            // Create a FileSender for this run
            let sender = FileSender()
            lock.withLock { currentSender = sender }

            // Synchronization: use a semaphore to wait for completion
            let semaphore = DispatchSemaphore(value: 0)
            var runError: String?
            var runBytesSent: UInt64 = 0
            var runCompleted = false

            sender.onProgress = { [weak self] sent in
                runBytesSent = sent
                self?.onRunProgress?(sent, payloadSize)
            }

            sender.onError = { message in
                runError = message
            }

            sender.onStateChange = { state in
                if state == .completed {
                    runCompleted = true
                    semaphore.signal()
                } else if state == .failed || state == .cancelled {
                    semaphore.signal()
                }
            }

            // Suppress per-run connection/header logs from the sub-sender
            sender.onLog = { _, _ in }

            let startTime = Date()

            // Send benchmark payload using the full SHRK protocol
            sender.send(
                to: endpoint,
                fileURL: fileURL,
                fileName: benchmarkFileName,
                fileSize: payloadSize,   // header advertises benchmark payload size
                chunkSize: chunkSize,
                byteLimit: payloadSize   // only send this many bytes from the file
            )

            // Wait for this run to finish
            semaphore.wait()

            lock.withLock { currentSender = nil }

            let endTime = Date()
            let duration = endTime.timeIntervalSince(startTime)

            guard !isCancelled else { return }

            if let error = runError, !runCompleted {
                onLog?("📊 Benchmark run failed for \(chunkLabel): \(error)", true)
                onError?("Benchmark failed at \(chunkLabel): \(error)")
                onStateChange?(.failed)
                return
            }

            let speedMBps = duration > 0
                ? Double(runBytesSent) / (1_048_576.0 * duration)
                : 0

            let result = BenchmarkRunResult(
                chunkSize: chunkSize,
                bytesSent: runBytesSent,
                duration: duration,
                averageSpeedMBps: speedMBps
            )
            results.append(result)
            onRunCompleted?(result)
            onLog?("  \(chunkLabel): \(result.formattedSpeed) (\(String(format: "%.1f", duration))s)", false)

            // Pause between runs (skip after the last one)
            if index < chunkSizes.count - 1 && !isCancelled {
                Thread.sleep(forTimeInterval: BenchmarkConfig.pauseBetweenRuns)
            }
        }

        guard !isCancelled else { return }

        // Determine the best chunk size
        let best = results.max(by: { $0.averageSpeedMBps < $1.averageSpeedMBps })!
        let benchmarkResult = BenchmarkResult(
            runs: results,
            recommendedChunkSize: best.chunkSize,
            benchmarkPayloadSize: payloadSize
        )

        onLog?("📊 Benchmark completed — recommended: \(best.formattedChunkSize) (\(best.formattedSpeed))", false)
        onBenchmarkCompleted?(benchmarkResult)
        onStateChange?(.completed)
    }

    deinit {
        currentSender?.cancel()
    }
}

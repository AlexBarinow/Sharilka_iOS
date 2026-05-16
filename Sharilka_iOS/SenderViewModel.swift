//
//  SenderViewModel.swift
//  Sharilka_iOS
//
//  Main ViewModel that orchestrates Bonjour discovery, file selection,
//  file transfer, and transfer benchmarking. Bridges BonjourBrowser,
//  FileSender, and BenchmarkRunner to SwiftUI.
//

import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SenderViewModel: ObservableObject {
    // MARK: - Published State

    // Discovery
    @Published var receivers: [DiscoveredReceiver] = []
    @Published var selectedReceiverID: String?
    @Published var isBrowsing = false

    // File
    @Published var selectedFile: FileInfo?
    @Published var showFilePicker = false

    // Transfer
    @Published var transferState: TransferState = .idle
    @Published var bytesSent: UInt64 = 0
    @Published var totalBytes: UInt64 = 0
    @Published var currentSpeedBytesPerSec: Double = 0
    @Published var lastError: String?

    // Log
    @Published var logEntries: [LogEntry] = []

    // Transfer timing
    @Published var transferStartTime: Date?
    @Published var transferEndTime: Date?

    // Transfer settings
    @Published var activeChunkSize: Int = TransferSettings.savedChunkSize

    // Benchmark state
    @Published var benchmarkState: BenchmarkState = .idle
    @Published var benchmarkRunIndex: Int = 0
    @Published var benchmarkCurrentChunkSize: Int = 0
    @Published var benchmarkBytesSent: UInt64 = 0
    @Published var benchmarkTotalBytes: UInt64 = 0
    @Published var benchmarkResults: [BenchmarkRunResult] = []
    @Published var benchmarkFinalResult: BenchmarkResult?
    @Published var benchmarkError: String?
    @Published var showBenchmarkResults = false

    // Speed calculation internals
    private var lastSpeedUpdateTime: Date = .now
    private var lastSpeedBytes: UInt64 = 0

    // Components
    let browser = BonjourBrowser()
    private let sender = FileSender()
    private var benchmarkRunner: BenchmarkRunner?
    private var syncTask: Task<Void, Never>?

    // MARK: - Computed Properties

    var selectedReceiver: DiscoveredReceiver? {
        guard let id = selectedReceiverID else { return nil }
        return receivers.first(where: { $0.id == id })
    }

    var progressFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesSent) / Double(totalBytes)
    }

    var progressPercent: Double {
        progressFraction * 100.0
    }

    var speedMBps: Double {
        currentSpeedBytesPerSec / (1024.0 * 1024.0)
    }

    var etaSeconds: Double? {
        guard currentSpeedBytesPerSec > 0, totalBytes > bytesSent else { return nil }
        let remaining = Double(totalBytes - bytesSent)
        return remaining / currentSpeedBytesPerSec
    }

    var etaFormatted: String {
        guard let eta = etaSeconds else { return "--:--" }
        if eta < 0 || eta > 360000 { return "--:--" }
        let totalSeconds = Int(eta)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var durationFormatted: String {
        guard let start = transferStartTime else { return "--:--" }
        let end = transferEndTime ?? .now
        let duration = end.timeIntervalSince(start)
        if duration < 1 {
            return String(format: "%.0f ms", duration * 1000)
        } else if duration < 60 {
            return String(format: "%.1f s", duration)
        } else {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    var canSend: Bool {
        selectedReceiver != nil && selectedFile != nil && !transferState.isActive && !benchmarkState.isActive
    }

    var canBenchmark: Bool {
        selectedReceiver != nil && selectedFile != nil && !transferState.isActive && !benchmarkState.isActive
    }

    var formattedBytesSent: String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesSent), countStyle: .file)
    }

    var formattedTotalBytes: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
    }

    var formattedActiveChunkSize: String {
        TransferSettings.formattedChunkSize(activeChunkSize)
    }

    var benchmarkProgressFraction: Double {
        guard benchmarkTotalBytes > 0 else { return 0 }
        return Double(benchmarkBytesSent) / Double(benchmarkTotalBytes)
    }

    var benchmarkOverallProgress: String {
        let total = BenchmarkConfig.chunkSizes.count
        if benchmarkState == .completed {
            return "\(total)/\(total)"
        }
        return "\(benchmarkRunIndex + 1)/\(total)"
    }

    // MARK: - Init

    init() {
        setupBrowserCallbacks()
        setupSenderCallbacks()
        startSyncTask()
    }

    deinit {
        syncTask?.cancel()
    }

    // MARK: - Discovery

    func startBrowsing() {
        browser.startBrowsing()
    }

    func stopBrowsing() {
        browser.stopBrowsing()
    }

    func selectReceiver(_ receiver: DiscoveredReceiver) {
        selectedReceiverID = receiver.id
        addLog("Selected receiver: \(receiver.name)")
        updateTransferStateIfReady()
    }

    // MARK: - File Selection

    func handleFileSelected(result: Result<URL, any Error>) {
        switch result {
        case .success(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }

            do {
                let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .isReadableKey])
                guard let fileSize = resourceValues.fileSize else {
                    addLog("Cannot determine file size", isError: true)
                    return
                }

                let info = FileInfo(
                    url: url,
                    name: url.lastPathComponent,
                    size: UInt64(fileSize)
                )
                selectedFile = info
                addLog("File selected: \"\(info.name)\" (\(info.formattedSize))")
                updateTransferStateIfReady()
            } catch {
                addLog("Error reading file info: \(error.localizedDescription)", isError: true)
            }

        case .failure(let error):
            addLog("File picker error: \(error.localizedDescription)", isError: true)
        }
    }

    func clearFile() {
        selectedFile = nil
        updateTransferStateIfReady()
    }

    // MARK: - Transfer

    func startTransfer() {
        guard let receiver = selectedReceiver,
              let file = selectedFile else {
            addLog("Cannot start: no receiver or file selected", isError: true)
            return
        }

        // Verify receiver is still available
        guard receivers.contains(where: { $0.id == receiver.id }) else {
            addLog("Selected receiver is no longer available", isError: true)
            lastError = "Receiver disappeared from the network"
            transferState = .failed
            return
        }

        // Reset transfer stats
        bytesSent = 0
        totalBytes = file.size
        currentSpeedBytesPerSec = 0
        lastError = nil
        lastSpeedUpdateTime = .now
        lastSpeedBytes = 0
        transferStartTime = .now
        transferEndTime = nil

        addLog("Starting transfer to \(receiver.name) (chunk: \(formattedActiveChunkSize))...")

        sender.send(
            to: receiver.endpoint,
            fileURL: file.url,
            fileName: file.name,
            fileSize: file.size,
            chunkSize: activeChunkSize
        )
    }

    func cancelTransfer() {
        sender.cancel()
        transferEndTime = .now
    }

    // MARK: - Benchmark

    func startBenchmark() {
        guard let receiver = selectedReceiver,
              let file = selectedFile else {
            addLog("Cannot benchmark: no receiver or file selected", isError: true)
            return
        }

        guard receivers.contains(where: { $0.id == receiver.id }) else {
            addLog("Selected receiver is no longer available", isError: true)
            benchmarkError = "Receiver disappeared from the network"
            benchmarkState = .failed
            return
        }

        // Reset benchmark state
        benchmarkState = .idle
        benchmarkRunIndex = 0
        benchmarkCurrentChunkSize = 0
        benchmarkBytesSent = 0
        benchmarkTotalBytes = 0
        benchmarkResults = []
        benchmarkFinalResult = nil
        benchmarkError = nil
        showBenchmarkResults = false

        let runner = BenchmarkRunner()
        benchmarkRunner = runner

        setupBenchmarkCallbacks(runner)

        runner.start(
            endpoint: receiver.endpoint,
            fileURL: file.url,
            originalFileName: file.name,
            originalFileSize: file.size
        )
    }

    func cancelBenchmark() {
        benchmarkRunner?.cancel()
        benchmarkRunner = nil
    }

    func applyRecommendedChunkSize() {
        guard let result = benchmarkFinalResult else { return }
        let newChunkSize = result.recommendedChunkSize
        TransferSettings.savedChunkSize = newChunkSize
        activeChunkSize = newChunkSize
        addLog("Applied recommended chunk size: \(TransferSettings.formattedChunkSize(newChunkSize))")
        showBenchmarkResults = false
    }

    func keepCurrentChunkSize() {
        showBenchmarkResults = false
        addLog("Kept current chunk size: \(formattedActiveChunkSize)")
    }

    // MARK: - Logging

    func addLog(_ message: String, isError: Bool = false) {
        let entry = LogEntry(message, isError: isError)
        logEntries.append(entry)
        if logEntries.count > 500 {
            logEntries.removeFirst(100)
        }
    }

    func clearLog() {
        logEntries.removeAll()
    }

    // MARK: - Private Helpers

    private func setupBrowserCallbacks() {
        browser.onLog = { [weak self] message, isError in
            self?.addLog(message, isError: isError)
        }
    }

    private func startSyncTask() {
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                guard let self else { return }
                self.receivers = self.browser.receivers
                self.isBrowsing = self.browser.isBrowsing

                // Deselect if the receiver disappeared during non-transfer
                if let selectedID = self.selectedReceiverID,
                   !self.receivers.contains(where: { $0.id == selectedID }) {
                    if !self.transferState.isActive && !self.benchmarkState.isActive {
                        self.selectedReceiverID = nil
                        self.updateTransferStateIfReady()
                    }
                }
            }
        }
    }

    private func setupSenderCallbacks() {
        sender.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.transferState = state
                if state == .completed || state == .failed || state == .cancelled {
                    self?.transferEndTime = .now
                }
            }
        }

        sender.onProgress = { [weak self] sent in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.bytesSent = sent
                self.updateSpeed(bytesNow: sent)
            }
        }

        sender.onError = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.lastError = message
            }
        }

        sender.onLog = { [weak self] message, isError in
            Task { @MainActor [weak self] in
                self?.addLog(message, isError: isError)
            }
        }

        sender.onComplete = { [weak self] in
            Task { @MainActor [weak self] in
                self?.addLog("✅ File delivered successfully")
            }
        }
    }

    private func setupBenchmarkCallbacks(_ runner: BenchmarkRunner) {
        runner.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.benchmarkState = state
                if state == .completed {
                    self.showBenchmarkResults = true
                }
            }
        }

        runner.onRunStarted = { [weak self] index, chunkSize in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.benchmarkRunIndex = index
                self.benchmarkCurrentChunkSize = chunkSize
                self.benchmarkBytesSent = 0
            }
        }

        runner.onRunProgress = { [weak self] sent, total in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.benchmarkBytesSent = sent
                self.benchmarkTotalBytes = total
            }
        }

        runner.onRunCompleted = { [weak self] result in
            Task { @MainActor [weak self] in
                self?.benchmarkResults.append(result)
            }
        }

        runner.onBenchmarkCompleted = { [weak self] result in
            Task { @MainActor [weak self] in
                self?.benchmarkFinalResult = result
            }
        }

        runner.onError = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.benchmarkError = message
            }
        }

        runner.onLog = { [weak self] message, isError in
            Task { @MainActor [weak self] in
                self?.addLog(message, isError: isError)
            }
        }
    }

    private func updateSpeed(bytesNow: UInt64) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSpeedUpdateTime)

        guard elapsed >= 0.3 else { return }

        let deltaBytes = Double(bytesNow - lastSpeedBytes)
        let instantSpeed = deltaBytes / elapsed

        // Exponential moving average
        let alpha = 0.3
        if currentSpeedBytesPerSec == 0 {
            currentSpeedBytesPerSec = instantSpeed
        } else {
            currentSpeedBytesPerSec = alpha * instantSpeed + (1 - alpha) * currentSpeedBytesPerSec
        }

        lastSpeedUpdateTime = now
        lastSpeedBytes = bytesNow
    }

    private func updateTransferStateIfReady() {
        if !transferState.isActive && transferState != .completed {
            if selectedReceiver != nil && selectedFile != nil {
                transferState = .ready
            } else if isBrowsing {
                transferState = .browsing
            } else {
                transferState = .idle
            }
        }
    }
}

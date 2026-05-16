//
//  ContentView.swift
//  Sharilka_iOS
//
//  Main UI: Discovery, File Selection, Transfer Progress, Transfer Benchmark, and Log.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var vm = SenderViewModel()
    @State private var showFilePicker = false

    var body: some View {
        NavigationStack {
            List {
                discoverySection
                fileSection
                transferSection
                benchmarkSection
                logSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Sharilka")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            vm.clearLog()
                        } label: {
                            Label("Clear Log", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        vm.handleFileSelected(result: .success(url))
                    }
                case .failure(let error):
                    vm.handleFileSelected(result: .failure(error))
                }
            }
            .onAppear {
                vm.startBrowsing()
            }
            .sheet(isPresented: $vm.showBenchmarkResults) {
                benchmarkResultsSheet
            }
        }
    }

    // MARK: - Discovery Section

    private var discoverySection: some View {
        Section {
            // Browsing control
            HStack {
                Circle()
                    .fill(vm.isBrowsing ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 10, height: 10)

                Text(vm.isBrowsing ? "Scanning for receivers..." : "Not scanning")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(vm.isBrowsing ? "Stop" : "Browse") {
                    if vm.isBrowsing {
                        vm.stopBrowsing()
                    } else {
                        vm.startBrowsing()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if vm.receivers.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No receivers found")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if vm.isBrowsing {
                            Text("Make sure Sharilka is running on your Mac")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 8)
                    Spacer()
                }
            } else {
                ForEach(vm.receivers) { receiver in
                    Button {
                        vm.selectReceiver(receiver)
                    } label: {
                        ReceiverRow(
                            receiver: receiver,
                            isSelected: vm.selectedReceiverID == receiver.id
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Label("Receivers", systemImage: "antenna.radiowaves.left.and.right")
        }
    }

    // MARK: - File Section

    private var fileSection: some View {
        Section {
            if let file = vm.selectedFile {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: fileIcon(for: file.name))
                            .foregroundStyle(.blue)
                            .font(.title3)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name)
                                .font(.body.weight(.medium))
                                .lineLimit(2)

                            Text(file.formattedSize)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button(role: .destructive) {
                            vm.clearFile()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button {
                showFilePicker = true
            } label: {
                Label(
                    vm.selectedFile == nil ? "Choose File" : "Change File",
                    systemImage: "doc.badge.plus"
                )
            }
            .disabled(vm.transferState.isActive || vm.benchmarkState.isActive)
        } header: {
            Label("File", systemImage: "doc")
        }
    }

    // MARK: - Transfer Section

    private var transferSection: some View {
        Section {
            // State indicator
            HStack {
                stateIcon
                Text(vm.transferState.rawValue)
                    .font(.headline)
                Spacer()
                if vm.transferState == .completed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                } else if vm.transferState == .failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.title3)
                }
            }

            // Current chunk size
            HStack {
                Label {
                    Text("Chunk size")
                        .font(.subheadline)
                } icon: {
                    Image(systemName: "square.stack.3d.up")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(vm.formattedActiveChunkSize)
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(.blue)
            }

            // Progress (shown during active transfer or after completion)
            if vm.transferState.isActive || vm.transferState == .completed || vm.transferState == .failed || vm.transferState == .cancelled {
                VStack(spacing: 8) {
                    ProgressView(value: vm.progressFraction)
                        .tint(progressColor)

                    HStack {
                        Text("\(vm.formattedBytesSent) / \(vm.formattedTotalBytes)")
                            .font(.caption.monospacedDigit())
                        Spacer()
                        Text(String(format: "%.1f%%", vm.progressPercent))
                            .font(.caption.monospacedDigit().weight(.medium))
                    }
                    .foregroundStyle(.secondary)

                    if vm.transferState.isActive || vm.transferState == .completed {
                        HStack {
                            // Speed
                            Label {
                                Text(String(format: "%.1f MB/s", vm.speedMBps))
                                    .font(.caption.monospacedDigit())
                            } icon: {
                                Image(systemName: "speedometer")
                                    .font(.caption)
                            }

                            Spacer()

                            // ETA
                            Label {
                                Text(vm.transferState == .completed ? "Done" : vm.etaFormatted)
                                    .font(.caption.monospacedDigit())
                            } icon: {
                                Image(systemName: "clock")
                                    .font(.caption)
                            }

                            Spacer()

                            // Duration
                            Label {
                                Text(vm.durationFormatted)
                                    .font(.caption.monospacedDigit())
                            } icon: {
                                Image(systemName: "timer")
                                    .font(.caption)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }

            // Error message
            if let error = vm.lastError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            // Action buttons
            HStack(spacing: 12) {
                Button {
                    vm.startTransfer()
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canSend)

                if vm.transferState.isActive {
                    Button(role: .destructive) {
                        vm.cancelTransfer()
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Label("Transfer", systemImage: "arrow.up.circle")
        }
    }

    // MARK: - Benchmark Section

    private var benchmarkSection: some View {
        Section {
            // Benchmark button
            Button {
                vm.startBenchmark()
            } label: {
                Label("Benchmark transfer settings", systemImage: "gauge.with.dots.needle.67percent")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .tint(.purple)
            .disabled(!vm.canBenchmark)

            // Cancel button while benchmark is active
            if vm.benchmarkState.isActive {
                Button(role: .destructive) {
                    vm.cancelBenchmark()
                } label: {
                    Label("Cancel Benchmark", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }

            // Benchmark progress
            if vm.benchmarkState.isActive {
                VStack(spacing: 8) {
                    HStack {
                        Text(vm.benchmarkState.rawValue)
                            .font(.subheadline.weight(.medium))

                        Spacer()

                        Text("Run \(vm.benchmarkOverallProgress)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if vm.benchmarkCurrentChunkSize > 0 {
                        HStack {
                            Text("Testing: \(TransferSettings.formattedChunkSize(vm.benchmarkCurrentChunkSize))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }

                    ProgressView(value: vm.benchmarkProgressFraction)
                        .tint(.purple)

                    HStack {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(vm.benchmarkBytesSent), countStyle: .file))
                            .font(.caption2.monospacedDigit())
                        Text("/")
                            .font(.caption2)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(vm.benchmarkTotalBytes), countStyle: .file))
                            .font(.caption2.monospacedDigit())
                        Spacer()
                    }
                    .foregroundStyle(.tertiary)
                }
            }

            // Completed inline results
            if !vm.benchmarkResults.isEmpty && !vm.benchmarkState.isActive && vm.benchmarkState != .idle {
                ForEach(vm.benchmarkResults) { run in
                    HStack {
                        Text(run.formattedChunkSize)
                            .font(.caption.weight(.medium))
                            .frame(width: 65, alignment: .leading)

                        Spacer()

                        Text(run.formattedSpeed)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)

                        if let best = vm.benchmarkFinalResult, run.chunkSize == best.recommendedChunkSize {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                        }
                    }
                }
            }

            // Benchmark error
            if let error = vm.benchmarkError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            // Note about temp files
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Benchmark transfers create temporary files on the Mac receiver.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } header: {
            Label("Transfer Benchmark", systemImage: "gauge.with.dots.needle.67percent")
        }
    }

    // MARK: - Benchmark Results Sheet

    private var benchmarkResultsSheet: some View {
        NavigationStack {
            List {
                if let result = vm.benchmarkFinalResult {
                    Section {
                        ForEach(result.runs) { run in
                            HStack {
                                Text(run.formattedChunkSize)
                                    .font(.body.weight(.medium))
                                    .frame(width: 80, alignment: .leading)

                                Spacer()

                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(run.formattedSpeed)
                                        .font(.body.monospacedDigit())

                                    Text(String(format: "%.1f s", run.duration))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }

                                if run.chunkSize == result.recommendedChunkSize {
                                    Image(systemName: "star.fill")
                                        .foregroundStyle(.yellow)
                                        .padding(.leading, 4)
                                } else {
                                    Image(systemName: "star")
                                        .foregroundStyle(.clear)
                                        .padding(.leading, 4)
                                }
                            }
                        }
                    } header: {
                        Text("Results")
                    }

                    Section {
                        HStack {
                            Text("Recommended")
                                .font(.subheadline)
                            Spacer()
                            Text(TransferSettings.formattedChunkSize(result.recommendedChunkSize))
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.purple)
                        }

                        HStack {
                            Text("Current")
                                .font(.subheadline)
                            Spacer()
                            Text(vm.formattedActiveChunkSize)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("Payload per run")
                                .font(.subheadline)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(result.benchmarkPayloadSize), countStyle: .file))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Recommendation")
                    }

                    Section {
                        Button {
                            vm.applyRecommendedChunkSize()
                        } label: {
                            Label("Apply recommended setting", systemImage: "checkmark.circle.fill")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)

                        Button {
                            vm.keepCurrentChunkSize()
                        } label: {
                            Label("Keep current setting", systemImage: "arrow.uturn.backward")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Benchmark Results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        vm.showBenchmarkResults = false
                    }
                }
            }
        }
    }

    // MARK: - Log Section

    private var logSection: some View {
        Section {
            if vm.logEntries.isEmpty {
                Text("No events yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(vm.logEntries.suffix(50)) { entry in
                    HStack(alignment: .top, spacing: 6) {
                        Text(entry.formattedTimestamp)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 75, alignment: .leading)

                        Text(entry.message)
                            .font(.caption)
                            .foregroundStyle(entry.isError ? .red : .primary)
                    }
                    .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                }
            }
        } header: {
            HStack {
                Label("Log", systemImage: "list.bullet.rectangle")
                Spacer()
                Text("\(vm.logEntries.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private var stateIcon: some View {
        switch vm.transferState {
        case .idle:
            Image(systemName: "moon.zzz")
                .foregroundStyle(.secondary)
        case .browsing:
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.blue)
        case .ready:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.green)
        case .connecting:
            ProgressView()
                .controlSize(.small)
        case .sendingHeader:
            ProgressView()
                .controlSize(.small)
        case .sendingFile:
            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(.blue)
        case .completed:
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "stop.circle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var progressColor: Color {
        switch vm.transferState {
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .orange
        default: return .blue
        }
    }

    private func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp":
            return "photo"
        case "mp4", "mov", "avi", "mkv", "m4v":
            return "film"
        case "mp3", "wav", "aac", "flac", "m4a":
            return "music.note"
        case "pdf":
            return "doc.richtext"
        case "zip", "tar", "gz", "rar", "7z":
            return "archivebox"
        case "txt", "md", "rtf":
            return "doc.text"
        case "swift", "py", "js", "ts", "c", "cpp", "h", "java":
            return "chevron.left.forwardslash.chevron.right"
        default:
            return "doc"
        }
    }
}

// MARK: - Receiver Row

struct ReceiverRow: View {
    let receiver: DiscoveredReceiver
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "desktopcomputer")
                .foregroundStyle(isSelected ? .green : .blue)
                .font(.title3)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(receiver.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)

                HStack(spacing: 8) {
                    if let platform = receiver.platform {
                        Label(platform, systemImage: "laptopcomputer")
                            .font(.caption2)
                    }
                    if let app = receiver.app {
                        Text(app)
                            .font(.caption2)
                    }
                    if let proto = receiver.protocolVersion {
                        Text("v\(proto)")
                            .font(.caption2)
                    }
                    if let port = receiver.portString {
                        Text(":\(port)")
                            .font(.caption2.monospacedDigit())
                    }
                }
                .foregroundStyle(.secondary)

                Text(receiver.endpointDescription)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.green)
                    .font(.body.weight(.semibold))
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

#Preview {
    ContentView()
}

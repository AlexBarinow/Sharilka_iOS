//
//  FileSender.swift
//  Sharilka_iOS
//
//  Handles a single file transfer over TCP using NWConnection.
//  Sends the exact SHRK binary protocol header then streams file data
//  from disk in chunks, never loading the entire file into memory.
//
//  Uses a bounded ChunkBuffer to pipeline file reading and network sending:
//  a reader task reads ahead into the buffer while the sender task consumes
//  and transmits chunks, reducing idle time between disk I/O and network I/O.
//
//  Supports both normal full-file transfer and benchmark mode where
//  only a limited number of bytes from the beginning of the file are sent.
//

import Combine
import Foundation
import Network

/// Performs file sending over a raw TCP connection using the SHRK protocol.
/// All callbacks are dispatched to MainActor by the caller (SenderViewModel).
final class FileSender: @unchecked Sendable {
    private var connection: NWConnection?
    private let sendQueue = DispatchQueue(label: "com.sharilka.sender", qos: .userInitiated)
    private let lock = NSLock()

    private var _cancelled = false
    private var isCancelled: Bool {
        get { lock.withLock { _cancelled } }
        set { lock.withLock { _cancelled = newValue } }
    }

    /// Active chunk buffer for the current transfer (used for cancellation).
    private var activeBuffer: ChunkBuffer?

    /// Active pipeline task for the current transfer (used for cancellation).
    private var pipelineTask: Task<Void, Never>?

    // Callbacks — called from sendQueue or Task, caller must dispatch to @MainActor
    var onStateChange: (@Sendable (TransferState) -> Void)?
    var onProgress: (@Sendable (UInt64) -> Void)?
    var onError: (@Sendable (String) -> Void)?
    var onLog: (@Sendable (String, Bool) -> Void)?
    var onComplete: (@Sendable () -> Void)?

    /// Start sending a file to the given endpoint.
    ///
    /// - Parameters:
    ///   - endpoint: The network endpoint to connect to.
    ///   - fileURL: The local file URL to read from.
    ///   - fileName: The filename to transmit in the protocol header.
    ///   - fileSize: The file size to transmit in the protocol header (and the number of bytes to send).
    ///   - chunkSize: The chunk size in bytes for streaming. Defaults to the saved setting.
    ///   - byteLimit: Optional maximum number of bytes to send from the file. If nil, sends `fileSize` bytes.
    ///                When set, this is the number of bytes actually transmitted, and `fileSize` in the header
    ///                should already be set to this value by the caller.
    nonisolated func send(
        to endpoint: NWEndpoint,
        fileURL: URL,
        fileName: String,
        fileSize: UInt64,
        chunkSize: Int = TransferSettings.savedChunkSize,
        byteLimit: UInt64? = nil
    ) {
        isCancelled = false

        let transmitSize = byteLimit ?? fileSize

        let tcp = NWParameters.tcp
        let connection = NWConnection(to: endpoint, using: tcp)
        lock.withLock {
            self.connection = connection
            self.activeBuffer = nil
            self.pipelineTask = nil
        }

        onStateChange?(.connecting)
        onLog?("Connecting to \(endpoint)...", false)

        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.isCancelled else { return }
            switch state {
            case .ready:
                self.onLog?("Connected", false)
                self.performTransfer(
                    connection: connection,
                    fileURL: fileURL,
                    fileName: fileName,
                    fileSize: fileSize,
                    transmitSize: transmitSize,
                    chunkSize: chunkSize
                )
            case .failed(let error):
                self.onLog?("Connection failed: \(error.localizedDescription)", true)
                self.onError?("Connection failed: \(error.localizedDescription)")
                self.onStateChange?(.failed)
            case .cancelled:
                break
            case .waiting(let error):
                self.onLog?("Connection waiting: \(error.localizedDescription)", false)
            default:
                break
            }
        }

        connection.start(queue: sendQueue)
    }

    /// Cancel the current transfer.
    nonisolated func cancel() {
        isCancelled = true

        // Cancel the buffer so both reader and sender tasks wake up and stop
        let (conn, buffer, task) = lock.withLock { () -> (NWConnection?, ChunkBuffer?, Task<Void, Never>?) in
            let c = connection
            let b = activeBuffer
            let t = pipelineTask
            connection = nil
            activeBuffer = nil
            pipelineTask = nil
            return (c, b, t)
        }

        if let buffer {
            Task { await buffer.cancel() }
        }
        task?.cancel()
        conn?.cancel()

        onLog?("Transfer cancelled by user", true)
        onStateChange?(.cancelled)
    }

    // MARK: - Transfer Logic

    private nonisolated func performTransfer(
        connection: NWConnection,
        fileURL: URL,
        fileName: String,
        fileSize: UInt64,
        transmitSize: UInt64,
        chunkSize: Int
    ) {
        guard !isCancelled else { return }

        // Build the exact SHRK header:
        // [4 bytes] "SHRK" magic
        // [1 byte]  protocol version (1)
        // [8 bytes] filename length (UInt64 LE)
        // [8 bytes] file size (UInt64 LE)
        // [N bytes] filename (UTF-8)

        guard let filenameData = fileName.data(using: .utf8) else {
            onError?("Filename cannot be encoded as UTF-8")
            onStateChange?(.failed)
            return
        }

        var header = Data()
        header.append(contentsOf: SharilkaProtocol.magic) // "SHRK"
        header.append(SharilkaProtocol.version)            // version 1

        var filenameLength = UInt64(filenameData.count).littleEndian
        header.append(Data(bytes: &filenameLength, count: 8))

        // Use fileSize for the header (which for benchmarks is already set to transmitSize by the caller)
        var fileSizeLE = fileSize.littleEndian
        header.append(Data(bytes: &fileSizeLE, count: 8))

        header.append(filenameData) // UTF-8 filename

        onStateChange?(.sendingHeader)
        onLog?("Sending header: \"\(fileName)\" (\(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)))", false)

        // Send the complete header
        connection.send(content: header, completion: .contentProcessed { [weak self] error in
            guard let self, !self.isCancelled else { return }

            if let error {
                self.onError?("Failed to send header: \(error.localizedDescription)")
                self.onLog?("Header send failed: \(error.localizedDescription)", true)
                self.onStateChange?(.failed)
                return
            }

            self.onLog?("Header sent (\(header.count) bytes)", false)
            self.startPipeline(
                connection: connection,
                fileURL: fileURL,
                transmitSize: transmitSize,
                chunkSize: chunkSize
            )
        })
    }

    // MARK: - Pipelined File Streaming

    /// Sets up the reader–sender pipeline using ChunkBuffer.
    private nonisolated func startPipeline(
        connection: NWConnection,
        fileURL: URL,
        transmitSize: UInt64,
        chunkSize: Int
    ) {
        guard !isCancelled else { return }

        onStateChange?(.sendingFile)
        onLog?("Streaming file data (prefetch buffer: \(ChunkBuffer.defaultCapacity) chunks)...", false)

        let buffer = ChunkBuffer(capacity: ChunkBuffer.defaultCapacity)
        lock.withLock { self.activeBuffer = buffer }

        // Launch the pipeline as a structured Task so both reader and sender run concurrently.
        let task = Task.detached { [weak self] in
            guard let self else { return }

            // Run reader and sender concurrently via a task group
            await withTaskGroup(of: Void.self) { group in
                // --- Reader task: reads file chunks from disk into the buffer ---
                group.addTask {
                    await self.readerTask(
                        buffer: buffer,
                        fileURL: fileURL,
                        transmitSize: transmitSize,
                        chunkSize: chunkSize
                    )
                }

                // --- Sender task: dequeues chunks from the buffer and sends over TCP ---
                group.addTask {
                    await self.senderTask(
                        buffer: buffer,
                        connection: connection,
                        transmitSize: transmitSize
                    )
                }
            }
        }

        lock.withLock { self.pipelineTask = task }
    }

    /// Reader: reads chunks from disk and enqueues them into the buffer.
    private nonisolated func readerTask(
        buffer: ChunkBuffer,
        fileURL: URL,
        transmitSize: UInt64,
        chunkSize: Int
    ) async {
        let needsSecurityScope = fileURL.startAccessingSecurityScopedResource()
        defer {
            if needsSecurityScope { fileURL.stopAccessingSecurityScopedResource() }
        }

        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            await buffer.fail("Cannot open file for reading")
            return
        }
        defer { fileHandle.closeFile() }

        var totalRead: UInt64 = 0

        while totalRead < transmitSize {
            // Check cancellation
            if isCancelled || Task.isCancelled {
                await buffer.cancel()
                return
            }

            let remaining = transmitSize - totalRead
            let readSize = min(Int(remaining), chunkSize)

            guard let chunk = try? fileHandle.read(upToCount: readSize), !chunk.isEmpty else {
                await buffer.fail("Failed to read file data at offset \(totalRead)")
                return
            }

            totalRead += UInt64(chunk.count)

            // Enqueue into the bounded buffer (suspends if buffer is full)
            let ok = await buffer.enqueue(chunk)
            if !ok {
                // Pipeline was cancelled or failed while we were waiting
                return
            }
        }

        // All bytes read — signal the buffer that production is complete
        await buffer.finish()
    }

    /// Sender: dequeues chunks from the buffer and sends them over the NWConnection.
    private nonisolated func senderTask(
        buffer: ChunkBuffer,
        connection: NWConnection,
        transmitSize: UInt64
    ) async {
        var totalSent: UInt64 = 0

        while let chunk = await buffer.dequeue() {
            // Check cancellation
            if isCancelled || Task.isCancelled {
                return
            }

            // Send chunk over the NWConnection, bridging callback to async
            let sendError: NWError? = await withCheckedContinuation { cont in
                connection.send(content: chunk, completion: .contentProcessed { error in
                    cont.resume(returning: error)
                })
            }

            if let error = sendError {
                self.onError?("Send failed: \(error.localizedDescription)")
                self.onLog?("Send error at \(totalSent) bytes: \(error.localizedDescription)", true)
                self.onStateChange?(.failed)
                await buffer.fail("Send failed: \(error.localizedDescription)")
                return
            }

            if isCancelled || Task.isCancelled {
                return
            }

            totalSent += UInt64(chunk.count)
            self.onProgress?(totalSent)
        }

        // Check if the buffer ended due to an error
        if let error = await buffer.getError() {
            self.onError?(error)
            self.onLog?(error, true)
            self.onStateChange?(.failed)
            return
        }

        // Check for cancellation
        if await buffer.getCancelled() || isCancelled {
            return
        }

        // All chunks sent successfully — signal EOF to the receiver
        let finalError: NWError? = await withCheckedContinuation { cont in
            connection.send(
                content: nil,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { error in
                    cont.resume(returning: error)
                }
            )
        }

        if let error = finalError {
            self.onLog?("Error completing connection: \(error.localizedDescription)", true)
        }

        self.onLog?("Transfer completed successfully", false)
        self.onStateChange?(.completed)
        self.onComplete?()

        let conn = self.lock.withLock { () -> NWConnection? in
            let c = self.connection
            self.connection = nil
            return c
        }
        conn?.cancel()
    }

    deinit {
        connection?.cancel()
    }
}

//
//  ChunkBuffer.swift
//  Sharilka_iOS
//
//  A bounded async queue used to pipeline file reading and network sending.
//  The reader (producer) enqueues Data chunks; the sender (consumer) dequeues them.
//  When the buffer is full the reader suspends; when empty the sender suspends.
//  Supports finish (reader done) and cancel/fail (abort both sides).
//

import Foundation

/// A bounded, async-safe buffer for pipelining file chunk reads and network sends.
///
/// - The producer calls `enqueue(_:)` which suspends when the buffer is full.
/// - The consumer calls `dequeue()` which suspends when the buffer is empty
///   and returns `nil` when the producer has finished and the buffer is drained.
/// - Either side can call `cancel()` or `fail(_:)` to abort the pipeline.
actor ChunkBuffer {
    /// Default prefetch capacity: number of chunks that can be buffered ahead.
    static let defaultCapacity = 4

    private var buffer: [Data] = []
    private let capacity: Int

    // State
    private var isFinished = false   // producer signalled completion
    private var isCancelled = false
    private var errorMessage: String?

    // Continuations for suspend/resume
    private var producerContinuation: CheckedContinuation<Void, Never>?
    private var consumerContinuation: CheckedContinuation<Data?, Never>?

    init(capacity: Int = ChunkBuffer.defaultCapacity) {
        self.capacity = max(1, capacity)
        self.buffer.reserveCapacity(capacity)
    }

    // MARK: - Producer API

    /// Enqueue a chunk. Suspends if the buffer is at capacity.
    /// Returns `false` if the pipeline was cancelled/failed (producer should stop).
    func enqueue(_ chunk: Data) async -> Bool {
        // If cancelled or failed, tell producer to stop
        if isCancelled || errorMessage != nil { return false }

        // If buffer is full, suspend the producer
        if buffer.count >= capacity {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                producerContinuation = cont
            }
            // Re-check after resuming
            if isCancelled || errorMessage != nil { return false }
        }

        buffer.append(chunk)

        // Wake up a waiting consumer
        if let cc = consumerContinuation {
            consumerContinuation = nil
            let item = buffer.removeFirst()
            cc.resume(returning: item)
        }

        return true
    }

    /// Signal that the producer is done (no more chunks will be enqueued).
    func finish() {
        isFinished = true

        // If consumer is waiting, wake it so it can drain & see nil
        if let cc = consumerContinuation {
            consumerContinuation = nil
            if buffer.isEmpty {
                cc.resume(returning: nil)
            } else {
                let item = buffer.removeFirst()
                cc.resume(returning: item)
            }
        }
    }

    // MARK: - Consumer API

    /// Dequeue the next chunk. Suspends if the buffer is empty and producer isn't done.
    /// Returns `nil` when all chunks have been consumed and producer has finished,
    /// or when the pipeline was cancelled.
    func dequeue() async -> Data? {
        // If cancelled or failed, stop consuming
        if isCancelled { return nil }
        if errorMessage != nil { return nil }

        // If buffer has data, return immediately
        if !buffer.isEmpty {
            let item = buffer.removeFirst()

            // Wake up a waiting producer (buffer has room now)
            if let pc = producerContinuation {
                producerContinuation = nil
                pc.resume()
            }

            return item
        }

        // Buffer is empty
        if isFinished {
            return nil // all done
        }

        // Suspend consumer until producer enqueues or finishes
        let item = await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            consumerContinuation = cont
        }

        // After resuming, wake producer if it was waiting (buffer consumed one slot)
        if let pc = producerContinuation {
            producerContinuation = nil
            pc.resume()
        }

        return item
    }

    // MARK: - Control

    /// Cancel the pipeline. Wakes both sides.
    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        buffer.removeAll()

        if let pc = producerContinuation {
            producerContinuation = nil
            pc.resume()
        }
        if let cc = consumerContinuation {
            consumerContinuation = nil
            cc.resume(returning: nil)
        }
    }

    /// Fail the pipeline with an error message. Wakes both sides.
    func fail(_ message: String) {
        guard errorMessage == nil, !isCancelled else { return }
        errorMessage = message
        buffer.removeAll()

        if let pc = producerContinuation {
            producerContinuation = nil
            pc.resume()
        }
        if let cc = consumerContinuation {
            consumerContinuation = nil
            cc.resume(returning: nil)
        }
    }

    /// Returns the error message if the pipeline failed.
    func getError() -> String? {
        errorMessage
    }

    /// Whether the pipeline was cancelled.
    func getCancelled() -> Bool {
        isCancelled
    }
}

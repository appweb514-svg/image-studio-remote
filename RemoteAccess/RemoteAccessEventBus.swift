import Foundation

/// Events emitted by the app and fanned out to Web UI clients over SSE.
/// The same events feed the SwiftUI views through the existing @Observable
/// stores — the bus is purely additive transport, never a second source of
/// truth.
enum RemoteAccessEvent {
    case jobCreated(jobID: String, family: String)
    case jobStarted(jobID: String, family: String, totalSteps: Int)
    case jobProgress(jobID: String, step: Int, totalSteps: Int, statusLine: String?)
    case jobPreview(jobID: String, jpegBase64: String)
    case jobCompleted(jobID: String, family: String, outputPath: String?, seed: Int?)
    case jobFailed(jobID: String, message: String)
    case jobCancelled(jobID: String)
    case queueChanged
    case modelLoading(label: String)
    case modelLoaded(label: String, memoryGB: Double?)
    case modelUnloaded
    case downloadProgress(message: String)
    case upscaleQueued(jobID: String)
    case upscaleStarted(jobID: String)
    case upscaleProgress(jobID: String, phase: String, tilesDone: Int, tilesTotal: Int)
    case upscaleCompleted(jobID: String, outputPath: String)
    case upscaleFailed(jobID: String, message: String)

    var name: String {
        switch self {
        case .jobCreated: "jobCreated"
        case .jobStarted: "jobStarted"
        case .jobProgress: "jobProgress"
        case .jobPreview: "jobPreview"
        case .jobCompleted: "jobCompleted"
        case .jobFailed: "jobFailed"
        case .jobCancelled: "jobCancelled"
        case .queueChanged: "queueChanged"
        case .modelLoading: "modelLoading"
        case .modelLoaded: "modelLoaded"
        case .modelUnloaded: "modelUnloaded"
        case .downloadProgress: "downloadProgress"
        case .upscaleQueued: "upscaleQueued"
        case .upscaleStarted: "upscaleStarted"
        case .upscaleProgress: "upscaleProgress"
        case .upscaleCompleted: "upscaleCompleted"
        case .upscaleFailed: "upscaleFailed"
        }
    }

    var payload: [String: String] {
        switch self {
        case let .jobCreated(jobID, family):
            return ["job_id": jobID, "family": family]
        case let .jobStarted(jobID, family, totalSteps):
            return ["job_id": jobID, "family": family, "total_steps": String(totalSteps)]
        case let .jobProgress(jobID, step, totalSteps, statusLine):
            var dict = [
                "job_id": jobID,
                "step": String(step),
                "total_steps": String(totalSteps),
            ]
            if let statusLine { dict["status_line"] = statusLine }
            return dict
        case let .jobPreview(jobID, jpegBase64):
            return ["job_id": jobID, "jpeg_base64": jpegBase64]
        case let .jobCompleted(jobID, family, outputPath, seed):
            var dict = ["job_id": jobID, "family": family]
            if let outputPath { dict["output_path"] = outputPath }
            if let seed { dict["seed"] = String(seed) }
            return dict
        case let .jobFailed(jobID, message):
            return ["job_id": jobID, "message": message]
        case let .jobCancelled(jobID):
            return ["job_id": jobID]
        case .queueChanged:
            return [String: String]()
        case let .modelLoading(label):
            return ["label": label]
        case let .modelLoaded(label, memoryGB):
            var dict = ["label": label]
            if let memoryGB { dict["memory_gb"] = String(format: "%.1f", memoryGB) }
            return dict
        case .modelUnloaded:
            return [String: String]()
        case let .downloadProgress(message):
            return ["message": message]
        case let .upscaleQueued(jobID):
            return ["job_id": jobID]
        case let .upscaleStarted(jobID):
            return ["job_id": jobID]
        case let .upscaleProgress(jobID, phase, tilesDone, tilesTotal):
            return [
                "job_id": jobID,
                "phase": phase,
                "tiles_done": String(tilesDone),
                "tiles_total": String(tilesTotal),
            ]
        case let .upscaleCompleted(jobID, outputPath):
            return ["job_id": jobID, "output_path": outputPath]
        case let .upscaleFailed(jobID, message):
            return ["job_id": jobID, "message": message]
        }
    }

    /// A complete SSE frame (`event:` + `data:` lines).
    var sseFrame: Data {
        var frame = "event: \(name)\ndata: "
        if let json = try? JSONEncoder().encode(payload) {
            frame += String(data: json, encoding: .utf8) ?? "{}"
        } else {
            frame += "{}"
        }
        frame += "\r\n\r\n"
        return Data(frame.utf8)
    }
}

/// Lightweight synchronous pub/sub. Publishers run on the main actor (stores
/// are main-actor isolated); each SSE subscriber gets its own AsyncStream that
/// the HTTP server pumps onto the socket.
@MainActor
final class RemoteAccessEventBus {
    private final class Subscriber {
        let id = UUID()
        var continuation: AsyncStream<Data>.Continuation
        init(continuation: AsyncStream<Data>.Continuation) {
            self.continuation = continuation
        }
    }

    private var subscribers: [Subscriber] = []

    /// Number of live SSE subscribers (for the Settings UI / status endpoint).
    var subscriberCount: Int { subscribers.count }

    /// Subscribe to the event stream. The returned stream ends when the bus is
    /// deallocated or `unsubscribe` is called.
    func subscribe() -> AsyncStream<Data> {
        AsyncStream { continuation in
            let subscriber = Subscriber(continuation: continuation)
            subscribers.append(subscriber)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.remove(subscriber.id)
                }
            }
        }
    }

    func unsubscribe(_ id: UUID) {
        remove(id)
    }

    func emit(_ event: RemoteAccessEvent) {
        let frame = event.sseFrame
        for subscriber in subscribers {
            subscriber.continuation.yield(frame)
        }
    }

    private func remove(_ id: UUID) {
        if let index = subscribers.firstIndex(where: { $0.id == id }) {
            subscribers[index].continuation.finish()
            subscribers.remove(at: index)
        }
    }
}

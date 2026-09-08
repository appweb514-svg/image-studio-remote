import AppKit
import Foundation

/// Bridges the observable job stores to the remote event bus. A background
/// task (main actor) polls at a fixed interval and diffs snapshots, emitting
/// `jobProgress`, `jobPreview`, `jobCompleted`, `jobFailed` and `queueChanged`
/// events. Polling was chosen over observation tracking because jobs mutate
/// `@Observable` fields on the main actor mid-run; a 400 ms cadence is well
/// under human perceptibility for progress bars and keeps SSE traffic bounded.
@MainActor
final class ProgressMonitor {
    private struct JobSnapshot {
        let status: String
        let currentStep: Int
        let totalSteps: Int
        let outputPath: String?
        let previewPath: String?
    }

    private struct Snapshot {
        var jobs: [String: JobSnapshot] = [:]
        var pendingCount = 0
        var loadedFingerprint: String?
        var loadedMemoryGB: Double?
    }

    private let service: GenerationService
    private let bus: RemoteAccessEventBus
    private var task: Task<Void, Never>?
    private var last = Snapshot()

    /// Preview frames are downscaled to this edge and JPEG-encoded.
    nonisolated static let previewMaxEdge: CGFloat = 512
    nonisolated static let previewJPEGQuality: CGFloat = 0.55

    init(service: GenerationService, bus: RemoteAccessEventBus) {
        self.service = service
        self.bus = bus
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func tick() {
        var snapshot = Snapshot()
        for storeJob in collectJobs() {
            let job = storeJob.job
            let key = job.id.uuidString
            snapshot.jobs[key] = JobSnapshot(
                status: statusKey(job.status),
                currentStep: job.currentStep,
                totalSteps: job.totalSteps,
                outputPath: job.outputPath,
                previewPath: job.latestStepwisePath
            )
            if !job.status.isTerminal {
                snapshot.pendingCount += 1
            }
        }
        snapshot.loadedFingerprint = service.fluxRunner.driver?.loadedFingerprint
        snapshot.loadedMemoryGB = service.fluxRunner.driver?.loadedMemoryGB

        emitDiffs(previous: last, current: snapshot)
        last = snapshot
    }

    private func collectJobs() -> [GenerationService.FamilyJob] {
        var jobs: [GenerationService.FamilyJob] = []
        for job in service.fluxStore.jobs { jobs.append(.init(family: .flux, job: job)) }
        for job in service.krea2Store.jobs { jobs.append(.init(family: .krea2, job: job)) }
        for job in service.zimageStore.jobs { jobs.append(.init(family: .zimage, job: job)) }
        if let ideogram = service.ideogramStore {
            for job in ideogram.jobs { jobs.append(.init(family: .ideogram4, job: job)) }
        }
        return jobs
    }

    private func statusKey(_ status: JobStatus) -> String {
        switch status {
        case .pending: "pending"
        case .running: "running"
        case .completed: "completed"
        case .cancelled: "cancelled"
        case .failed: "failed"
        }
    }

    private func emitDiffs(previous: Snapshot, current: Snapshot) {
        for (id, currentJob) in current.jobs {
            let prev = previous.jobs[id]

            if prev == nil, currentJob.status == "pending" {
                // creation events are emitted by the service at enqueue time
                continue
            }

            if currentJob.status == "running" {
                if prev?.status != "running", currentJob.totalSteps > 0 {
                    bus.emit(.jobStarted(jobID: id, family: "", totalSteps: currentJob.totalSteps))
                }
                if currentJob.currentStep != prev?.currentStep {
                    var statusLine: String?
                    if id == service.fluxRunner.activeJob?.id.uuidString {
                        statusLine = service.fluxRunner.activeJob?.statusLine
                    }
                    bus.emit(.jobProgress(jobID: id, step: currentJob.currentStep, totalSteps: currentJob.totalSteps, statusLine: statusLine))
                }
                if let previewPath = currentJob.previewPath, previewPath != prev?.previewPath {
                    if let frame = Self.downscaledJPEG(path: previewPath) {
                        bus.emit(.jobPreview(jobID: id, jpegBase64: frame.base64EncodedString()))
                    }
                }
            }

            if currentJob.status == "completed", prev?.status != "completed" {
                bus.emit(.jobCompleted(
                    jobID: id,
                    family: "",
                    outputPath: currentJob.outputPath,
                    seed: nil
                ))
                // Gallery scan so the web history sees the new image — mirrors
                // ContentView's onChange-driven scans for the native UI.
                service.gallery.scan(outputDir: service.settings.outputDir)
            }

            if (currentJob.status == "failed" || currentJob.status == "cancelled"),
               prev?.status != currentJob.status {
                if currentJob.status == "failed" {
                    bus.emit(.jobFailed(jobID: id, message: ""))
                } else {
                    bus.emit(.jobCancelled(jobID: id))
                }
            }
        }

        if previous.pendingCount != current.pendingCount {
            bus.emit(.queueChanged)
        }

        if previous.loadedFingerprint != current.loadedFingerprint {
            if current.loadedFingerprint == nil, previous.loadedFingerprint != nil {
                bus.emit(.modelUnloaded)
            } else if let fingerprint = current.loadedFingerprint {
                bus.emit(.modelLoaded(
                    label: fingerprint,
                    memoryGB: current.loadedMemoryGB
                ))
            }
        }
    }

    /// Downscale + JPEG-encode a preview frame for network transport.
    nonisolated static func downscaledJPEG(path: String) -> Data? {
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        var targetRect = CGRect(origin: .zero, size: image.size)
        let longestEdge = max(image.size.width, image.size.height)
        if longestEdge > previewMaxEdge {
            let scale = previewMaxEdge / longestEdge
            targetRect.size = CGSize(
                width: image.size.width * scale,
                height: image.size.height * scale
            )
        }
        guard let cgImage = image.cgImage(
            forProposedRect: &targetRect,
            context: nil,
            hints: [NSImageRep.HintKey.interpolation: NSImageInterpolation.low.rawValue]
        ) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: previewJPEGQuality])
    }
}

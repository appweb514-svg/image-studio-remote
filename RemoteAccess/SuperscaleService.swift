import CoreGraphics
import CryptoKit
import Foundation
import SuperscaleKit

/// In-process integration of Superscale (Real-ESRGAN on the Neural Engine via
/// CoreML). Holds loaded pipelines in memory so consecutive upscales skip the
/// model load entirely (warm residency), and computes recommended output
/// resolutions for a given model.
@MainActor
@Observable
final class SuperscaleService {
    // MARK: - Job model (in-memory; upscale is seconds-fast)

    struct UpscaleJob: Identifiable {
        enum Status: String {
            case queued, running, completed, failed
        }

        let id = UUID()
        var status: Status = .queued
        var inputPath: String
        var outputPath: String?
        var modelName: String
        var phase: String = ""
        var tilesDone: Int = 0
        var tilesTotal: Int = 0
        var error: String?
        var createdAt = Date()
    }

    // MARK: - State

    private let settings: AppSettings
    private let bus: RemoteAccessEventBus
    private var jobs: [UUID: UpscaleJob] = [:]
    private var jobOrder: [UUID] = []

    /// Warm residency: name of the model currently held in memory.
    private(set) var warmModelName: String?
    private(set) var isUpscaling = false

    /// Serialized access to the pipelines (CoreML inference is not reentrant
    /// across models on the ANE and `Pipeline` is not Sendable).
    private let runner = PipelineRunner()
    private var runTask: Task<Void, Never>?

    init(settings: AppSettings, bus: RemoteAccessEventBus) {
        self.settings = settings
        self.bus = bus
    }

    var jobCount: Int { jobOrder.count }
    var pendingJobCount: Int { jobs.values.filter { $0.status == .queued || $0.status == .running }.count }

    func job(id: UUID) -> UpscaleJob? { jobs[id] }

    /// Most recent jobs, newest first (bounded snapshot for the API).
    func recentJobs() -> [UpscaleJob] {
        jobOrder.suffix(50).compactMap { jobs[$0] }.reversed()
    }

    // MARK: - Models

    struct ModelStatus: Encodable {
        let name: String
        let displayName: String
        let scale: Int
        let tileSize: Int
        let isDefault: Bool
        let installed: Bool
        let downloading: Bool
        let supportsFaceEnhance: Bool
        let shortDescription: String
        let detailedDescription: String
    }

    func modelStatuses() -> [ModelStatus] {
        SuperscaleKit.ModelRegistry.models.map { model in
            ModelStatus(
                name: model.name,
                displayName: model.displayName,
                scale: model.scale,
                tileSize: model.tileSize,
                isDefault: model.isDefault,
                installed: SuperscaleKit.ModelRegistry.isInstalled(model),
                downloading: downloadInProgress.contains(model.name),
                supportsFaceEnhance: FaceModelRegistry.isInstalled,
                shortDescription: model.shortDescription,
                detailedDescription: model.detailedDescription
            )
        }
    }

    func modelInfo(named name: String?) -> ModelInfo? {
        if let name, let info = SuperscaleKit.ModelRegistry.model(named: name) {
            return info
        }
        return SuperscaleKit.ModelRegistry.models.first { $0.isDefault }
    }

    // MARK: - Recommended resolutions

    struct Recommendation: Encodable {
        let label: String
        let width: Int
        let height: Int
        let note: String
        let recommended: Bool
    }

    /// Recommended output resolutions for a source image and model:
    /// native model scale (×2/×4), intermediate ×2, and "fit within"
    /// 2K/4K targets rounded to a diffusion-friendly multiple of 8.
    func recommendations(sourceWidth: Int, sourceHeight: Int, modelName: String?) -> [Recommendation] {
        guard sourceWidth >= 8, sourceHeight >= 8,
              let info = modelInfo(named: modelName) else { return [] }
        let scale = info.scale
        let round8: (Double) -> Int = { max(8, Int(($0 / 8.0).rounded() * 8)) }
        var out: [Recommendation] = []

        let nativeW = sourceWidth * scale
        let nativeH = sourceHeight * scale
        let nativeTooBig = max(nativeW, nativeH) > 4096

        out.append(Recommendation(
            label: "Natif ×\(scale)",
            width: nativeW,
            height: nativeH,
            note: info.shortDescription,
            recommended: !nativeTooBig
        ))

        if scale == 4 {
            out.append(Recommendation(
                label: "×2",
                width: sourceWidth * 2,
                height: sourceHeight * 2,
                note: "Détail plus fidèle à la source, moins d'hallucination.",
                recommended: false
            ))
        }

        // Fit-within targets (aspect preserved), only when they upscale.
        struct Target { let name: String; let w: Int; let h: Int }
        for target in [Target(name: "2K", w: 2560, h: 1440), Target(name: "4K", w: 3840, h: 2160)] {
            let factor = min(Double(target.w) / Double(sourceWidth), Double(target.h) / Double(sourceHeight))
            guard factor > 1.0 else { continue }
            let fitW = round8(Double(sourceWidth) * factor)
            let fitH = round8(Double(sourceHeight) * factor)
            let isRec = target.name == "4K" && nativeTooBig
            out.append(Recommendation(
                label: "Fit \(target.name)",
                width: fitW,
                height: fitH,
                note: "Entre dans \(target.w)×\(target.h) en gardant le ratio.",
                recommended: isRec
            ))
        }

        if !out.contains(where: \.recommended), let first = out.first {
            out[0] = Recommendation(
                label: first.label,
                width: first.width,
                height: first.height,
                note: first.note,
                recommended: true
            )
        }
        return out
    }

    // MARK: - Model download

    struct ModelArtifact {
        let name: String
        let filename: String
        let sha256: String
        let url: URL
    }

    /// Upstream model artifacts (Superscale release `models-v1`, Real-ESRGAN
    /// weights, BSD-3-Clause — see docs/model-licensing.md).
    static let artifacts: [ModelArtifact] = [
        .init(name: "realesrgan-x4plus", filename: "RealESRGAN_x4plus.mlpackage",
              sha256: "34e4be0f99a82cd28fbf761de3ede3e9ff6fa3607b4ddce2f4743e686660f236",
              url: URL(string: "https://github.com/tigger04/superscale/releases/download/models-v1/RealESRGAN_x4plus.mlpackage.zip")!),
        .init(name: "realesrgan-x2plus", filename: "RealESRGAN_x2plus.mlpackage",
              sha256: "d5cbd517095007f8f5f6bfa00b950130d583feb02a18366937996c105f54d82b",
              url: URL(string: "https://github.com/tigger04/superscale/releases/download/models-v1/RealESRGAN_x2plus.mlpackage.zip")!),
        .init(name: "realesrnet-x4plus", filename: "RealESRNet_x4plus.mlpackage",
              sha256: "976b8cbc2c01fb0896fb59d34e7d8a12df37383831aa9a376097b8b4c53c9731",
              url: URL(string: "https://github.com/tigger04/superscale/releases/download/models-v1/RealESRNet_x4plus.mlpackage.zip")!),
        .init(name: "realesrgan-anime-6b", filename: "RealESRGAN_x4plus_anime_6B.mlpackage",
              sha256: "ae5af5d3dd93dec304fc7c58b5c1da7bf2191751cfb1adf81d5f3323ded24ea5",
              url: URL(string: "https://github.com/tigger04/superscale/releases/download/models-v1/RealESRGAN_x4plus_anime_6B.mlpackage.zip")!),
        .init(name: "realesr-animevideov3", filename: "realesr-animevideov3.mlpackage",
              sha256: "45fcba65e58d5ef968cdb834a7f9b1cd8231e6757911425c130180f797b8a09a",
              url: URL(string: "https://github.com/tigger04/superscale/releases/download/models-v1/realesr-animevideov3.mlpackage.zip")!),
        .init(name: "realesr-general-x4v3", filename: "realesr-general-x4v3.mlpackage",
              sha256: "367f383f8a3e3d3197fccd0875c3936d8ae8e9d70cedbb16182ab91d76d9a914",
              url: URL(string: "https://github.com/tigger04/superscale/releases/download/models-v1/realesr-general-x4v3.mlpackage.zip")!),
        .init(name: "realesr-general-wdn-x4v3", filename: "realesr-general-wdn-x4v3.mlpackage",
              sha256: "d77a916e21e2e063174e86c48fd36649eaefac1c6fad42d505339f2c9906ad99",
              url: URL(string: "https://github.com/tigger04/superscale/releases/download/models-v1/realesr-general-wdn-x4v3.mlpackage.zip")!),
    ]

    private var downloadInProgress: Set<String> = []

    static var modelsInstallDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("superscale/models", isDirectory: true)
    }

    func downloadModel(named name: String) async throws {
        guard let artifact = Self.artifacts.first(where: { $0.name == name }) else {
            throw UpscaleError.unknownModel(name)
        }
        guard !downloadInProgress.contains(name) else { return }
        downloadInProgress.insert(name)
        bus.emit(.downloadProgress(message: "Téléchargement \(name)…"))
        defer { downloadInProgress.remove(name) }

        let (tempURL, response) = try await URLSession.shared.download(from: artifact.url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpscaleError.downloadFailed(name)
        }

        // Integrity check before anything touches the models directory.
        let data = try Data(contentsOf: tempURL)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == artifact.sha256 else {
            throw UpscaleError.checksumMismatch(name)
        }

        let installDir = Self.modelsInstallDirectory
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
        let extractDir = installDir.appendingPathComponent(".extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", tempURL.path, extractDir.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: extractDir)
            throw UpscaleError.extractionFailed(name)
        }

        let packageURL = extractDir.appendingPathComponent(artifact.filename)
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            try? FileManager.default.removeItem(at: extractDir)
            throw UpscaleError.extractionFailed(name)
        }
        let destination = installDir.appendingPathComponent(artifact.filename)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: packageURL, to: destination)
        try? FileManager.default.removeItem(at: extractDir)
        try? FileManager.default.removeItem(at: tempURL)

        bus.emit(.downloadProgress(message: "Modèle \(name) installé"))
    }

    enum UpscaleError: LocalizedError {
        case unknownModel(String)
        case downloadFailed(String)
        case checksumMismatch(String)
        case extractionFailed(String)
        case notInstalled(String)
        case inputNotFound
        case inferenceFailed(String)

        var errorDescription: String? {
            switch self {
            case .unknownModel(let n): "modèle inconnu: \(n)"
            case .downloadFailed(let n): "téléchargement impossible: \(n)"
            case .checksumMismatch(let n): "somme de contrôle invalide: \(n)"
            case .extractionFailed(let n): "extraction impossible: \(n)"
            case .notInstalled(let n): "modèle non installé: \(n)"
            case .inputNotFound: "image source introuvable"
            case .inferenceFailed(let m): m
            }
        }
    }

    // MARK: - Upscale (warm, serialized)

    struct UpscaleRequest {
        var inputURL: URL
        var outputURL: URL
        var modelName: String?
        var requestedScale: Double?
        var targetWidth: Int?
        var targetHeight: Int?
        var stretch: Bool
        var faceEnhance: Bool
    }

    /// Drain queued upscale jobs one at a time (ANE serialization mirrors
    /// GenerationCoordinator for generative runs).
    private func pumpQueue() {
        guard let nextID = jobOrder.first(where: { jobs[$0]?.status == .queued }),
              let next = jobs[nextID] else {
            runTask = nil
            isUpscaling = false
            return
        }
        isUpscaling = true
        runTask = Task { [weak self] in
            await self?.run(next)
            self?.pumpQueue()
        }
    }

    private func run(_ job: UpscaleJob) async {
        mutate(job.id) { $0.status = .running }
        bus.emit(.upscaleStarted(jobID: job.id.uuidString))

        let request = requestForJob(job)
        let settingsRef = settings
        let serviceName = request.modelName ?? job.modelName

        do {
            guard FileManager.default.fileExists(atPath: request.inputURL.path) else {
                throw UpscaleError.inputNotFound
            }
            guard let info = modelInfo(named: serviceName) else {
                throw UpscaleError.unknownModel(serviceName)
            }
            guard SuperscaleKit.ModelRegistry.isInstalled(info) else {
                throw UpscaleError.notInstalled(serviceName)
            }

            let result: String = try await runner.run(
                modelName: info.name,
                keepWarm: settingsRef.superscaleKeepWarm,
                faceEnhance: request.faceEnhance
            ) { [weak self] pipeline in
                pipeline.onProgress = { progress in
                    Task { @MainActor [weak self] in
                        self?.handleProgress(job.id, progress)
                    }
                }
                try pipeline.process(
                    input: request.inputURL,
                    output: request.outputURL,
                    requestedScale: request.requestedScale,
                    targetWidth: request.targetWidth,
                    targetHeight: request.targetHeight,
                    stretch: request.stretch
                )
            }

            warmModelName = result
            mutate(job.id) {
                $0.status = .completed
                $0.outputPath = request.outputURL.path
            }
            bus.emit(.upscaleCompleted(jobID: job.id.uuidString, outputPath: request.outputURL.path))
        } catch {
            let message = (error as? UpscaleError)?.errorDescription ?? error.localizedDescription
            mutate(job.id) {
                $0.status = .failed
                $0.error = message
            }
            bus.emit(.upscaleFailed(jobID: job.id.uuidString, message: message))
        }
    }

    private func requestForJob(_ job: UpscaleJob) -> UpscaleRequest {
        // The queued job carries everything; reconstruct from stored state.
        // Options are captured at enqueue time via `pendingRequests`.
        pendingRequests[job.id] ?? UpscaleRequest(
            inputURL: URL(fileURLWithPath: job.inputPath),
            outputURL: defaultOutputURL(for: job.inputPath, model: job.modelName),
            modelName: job.modelName,
            requestedScale: nil, targetWidth: nil, targetHeight: nil,
            stretch: false, faceEnhance: settings.superscaleFaceEnhance
        )
    }

    private var pendingRequests: [UUID: UpscaleRequest] = [:]

    private func handleProgress(_ id: UUID, _ progress: SuperscaleKit.PipelineProgress) {
        let phase = "\(progress)"
        mutate(id) { job in
            job.phase = phase
        }
        if case let .tiling(done, total) = progress {
            mutate(id) {
                $0.tilesDone = done
                $0.tilesTotal = total
            }
            bus.emit(.upscaleProgress(jobID: id.uuidString, phase: phase, tilesDone: done, tilesTotal: total))
        } else {
            bus.emit(.upscaleProgress(jobID: id.uuidString, phase: phase, tilesDone: 0, tilesTotal: 0))
        }
    }

    /// Enqueue an upscale with full options.
    func enqueue(
        inputURL: URL,
        outputURL: URL? = nil,
        modelName: String?,
        requestedScale: Double? = nil,
        targetWidth: Int? = nil,
        targetHeight: Int? = nil,
        stretch: Bool = false,
        faceEnhance: Bool? = nil
    ) -> UUID {
        let info = modelInfo(named: modelName)
        let job = UpscaleJob(
            inputPath: inputURL.path,
            modelName: info?.name ?? "realesrgan-x4plus"
        )
        let request = UpscaleRequest(
            inputURL: inputURL,
            outputURL: outputURL ?? defaultOutputURL(for: inputURL.path, model: job.modelName),
            modelName: job.modelName,
            requestedScale: requestedScale,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            stretch: stretch,
            faceEnhance: faceEnhance ?? settings.superscaleFaceEnhance
        )
        jobs[job.id] = job
        jobOrder.append(job.id)
        pendingRequests[job.id] = request
        pruneJobs()
        bus.emit(.upscaleQueued(jobID: job.id.uuidString))

        guard runTask == nil else { return job.id }
        pumpQueue()
        return job.id
    }

    private func defaultOutputURL(for inputPath: String, model: String) -> URL {
        let board = settings.outputDir.isEmpty
            ? JobStore.appSupportURL.appendingPathComponent("output", isDirectory: true)
            : URL(fileURLWithPath: settings.outputDir)
        let upscaledDir = board.appendingPathComponent("Upscaled", isDirectory: true)
        try? FileManager.default.createDirectory(at: upscaledDir, withIntermediateDirectories: true)
        let base = URL(fileURLWithPath: inputPath).deletingPathExtension().lastPathComponent
        let suffix = model.contains("x2") ? "2x" : "4x"
        return upscaledDir.appendingPathComponent("\(base)_upscaled-\(suffix).png")
    }

    private func mutate(_ id: UUID, _ change: (inout UpscaleJob) -> Void) {
        guard var job = jobs[id] else { return }
        change(&job)
        jobs[id] = job
    }

    private func pruneJobs() {
        guard jobOrder.count > 50 else { return }
        let keep = Set(jobOrder.suffix(50))
        for id in jobOrder where !keep.contains(id) {
            jobs.removeValue(forKey: id)
            pendingRequests.removeValue(forKey: id)
        }
        jobOrder = jobOrder.suffix(50)
    }
}

/// Actor owning the warm `Pipeline` instances. `Pipeline` is not Sendable and
/// its `process` is synchronous; confining it here keeps the API safe while
/// the CoreML model stays resident between calls (compile cache handles the
/// ~4 s compile only on the very first load).
private actor PipelineRunner {
    private struct WarmEntry {
        let pipeline: SuperscaleKit.Pipeline
        let faceEnhance: Bool
    }

    private var warm: [String: WarmEntry] = [:]

    func run(
        modelName: String,
        keepWarm: Bool,
        faceEnhance: Bool,
        _ body: (SuperscaleKit.Pipeline) throws -> Void
    ) async throws -> String {
        let pipeline: SuperscaleKit.Pipeline
        if let entry = warm[modelName], entry.faceEnhance == faceEnhance {
            pipeline = entry.pipeline
        } else {
            pipeline = try SuperscaleKit.Pipeline(modelName: modelName, faceEnhance: faceEnhance)
            if keepWarm {
                warm[modelName] = WarmEntry(pipeline: pipeline, faceEnhance: faceEnhance)
            }
        }
        try body(pipeline)
        if !keepWarm { warm.removeValue(forKey: modelName) }
        return modelName
    }

    func evictAll() {
        warm.removeAll()
    }
}

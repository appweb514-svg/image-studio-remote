import Foundation

/// Application-service facade over the existing job stores, runners, gallery
/// and settings. The remote API never touches mflux or subprocesses directly —
/// it goes through here, exactly like the SwiftUI surfaces do.
///
/// Concurrency model: everything is main-actor isolated (stores are
/// `@Observable @MainActor`); enqueue mirrors `ContentView.generate()`.
@MainActor
final class GenerationService {
    let settings: AppSettings
    let fluxStore: JobStore
    let fluxRunner: FluxJobRunner
    let krea2Store: Krea2JobStore
    let krea2Runner: Krea2JobRunner
    let zimageStore: ZImageJobStore
    let zimageRunner: ZImageJobRunner
    let coordinator: GenerationCoordinator
    let timing: TimingStore
    let gallery: GalleryStore
    let bus: RemoteAccessEventBus

    init(
        settings: AppSettings,
        fluxStore: JobStore,
        fluxRunner: FluxJobRunner,
        krea2Store: Krea2JobStore,
        krea2Runner: Krea2JobRunner,
        zimageStore: ZImageJobStore,
        zimageRunner: ZImageJobRunner,
        coordinator: GenerationCoordinator,
        timing: TimingStore,
        gallery: GalleryStore,
        bus: RemoteAccessEventBus
    ) {
        self.settings = settings
        self.fluxStore = fluxStore
        self.fluxRunner = fluxRunner
        self.krea2Store = krea2Store
        self.krea2Runner = krea2Runner
        self.zimageStore = zimageStore
        self.zimageRunner = zimageRunner
        self.coordinator = coordinator
        self.timing = timing
        self.gallery = gallery
        self.bus = bus
    }

    // MARK: - Request model

    struct GenerateRequest: Decodable {
        var family: String?
        var model: String?
        var customRepo: String?
        var prompt: String?
        var negativePrompt: String?
        var width: Int?
        var height: Int?
        var steps: Int?
        var guidance: Double?
        var seed: Int?
        var batch: Int?
        var quantize: Int?
        var lowRam: Bool?
        var board: String?
        var imagePath: String?
        var imageStrength: Double?
        var editMode: Bool?
        var editImagePaths: [String]?
        var loras: [LoraRequest]?

        struct LoraRequest: Decodable {
            var path: String
            var strength: Double?
            var enabled: Bool?
        }
    }

    enum ServiceError: LocalizedError {
        case unknownFamily(String)
        case unknownModel(String)
        case emptyPrompt
        case jobNotFound
        case invalidDimensions

        var errorDescription: String? {
            switch self {
            case .unknownFamily(let f): "famille de modèle inconnue: \(f)"
            case .unknownModel(let m): "modèle inconnu: \(m)"
            case .emptyPrompt: "prompt requis"
            case .jobNotFound: "job introuvable"
            case .invalidDimensions: "dimensions invalides (64–4096, multiples de 8)"
            }
        }
    }

    // MARK: - Enqueue

    func enqueue(_ request: GenerateRequest) throws {
        let family = request.family ?? "flux"
        switch family {
        case ModelFamily.flux.id: _ = try enqueueFlux(request)
        case ModelFamily.krea2.id: _ = try enqueueKrea2(request)
        case ModelFamily.zimage.id: _ = try enqueueZImage(request)
        default: throw ServiceError.unknownFamily(family)
        }
        bus.emit(.queueChanged)
        settings.ensureOutputDirExists()
    }

    private func validatedDimensions(_ request: GenerateRequest, defaultWidth: Int, defaultHeight: Int) throws -> (Int, Int) {
        let width = request.width ?? defaultWidth
        let height = request.height ?? defaultHeight
        let valid = { $0 >= 64 && $0 <= 4096 && $0 % 8 == 0 }
        guard valid(width), valid(height) else { throw ServiceError.invalidDimensions }
        return (width, height)
    }

    private func batchSeeds(_ request: GenerateRequest) -> [Int] {
        let count = min(max(request.batch ?? 1, 1), 16)
        guard count > 1 else { return [] }
        let base = request.seed ?? -1
        if base == -1 {
            return (0..<count).map { _ in Int.random(in: 0...Int.max) }
        }
        return (0..<count).map { base + $0 }
    }

    private func loraEntries(_ request: GenerateRequest) -> [LoraEntry] {
        (request.loras ?? []).map { lora in
            LoraEntry(
                path: lora.path,
                strength: lora.strength ?? 1.0,
                enabled: lora.enabled ?? true,
                notes: "",
                modelFamily: .flux
            )
        }
    }

    private func enqueueFlux(_ request: GenerateRequest) throws -> [String] {
        guard let prompt = request.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
            throw ServiceError.emptyPrompt
        }
        let variant: FluxModelVariant
        if let repo = request.customRepo, !repo.isEmpty {
            variant = .custom
        } else if let raw = request.model, let parsed = FluxModelVariant(rawValue: raw), parsed != .custom {
            variant = parsed
        } else {
            variant = settings.defaultModel
        }
        let (width, height) = try validatedDimensions(request, defaultWidth: settings.defaultWidth, defaultHeight: settings.defaultHeight)
        // Edit mode (mflux-generate-flux2-edit): 1+ input images, prompt
        // describes the change (angle, texture, color, scenery, merge…).
        let isEditMode = request.editMode ?? false
        let editImagePaths = isEditMode ? (request.editImagePaths ?? []) : []
        if isEditMode && editImagePaths.isEmpty {
            throw ServiceError.emptyPrompt // reuse: "no input image" case below uses same 400 path
        }
        let job = FluxJob(
            model: variant,
            customModelRepo: request.customRepo ?? "",
            customBaseModel: .flux2Klein4B,
            prompt: prompt,
            negativePrompt: request.negativePrompt ?? "",
            width: width,
            height: height,
            seed: request.seed ?? -1,
            seeds: batchSeeds(request),
            steps: request.steps ?? variant.defaultSteps,
            guidance: request.guidance ?? variant.defaultGuidance,
            loras: loraEntries(request),
            quantize: request.quantize ?? variant.recommendedQuantize,
            lowRam: request.lowRam ?? false,
            imagePath: isEditMode ? "" : (request.imagePath ?? ""),
            imageStrength: request.imageStrength ?? 0.75,
            isEditMode: isEditMode,
            editImagePaths: editImagePaths,
            board: request.board ?? "Default"
        )
        settings.recordPromptUse(prompt)
        fluxStore.add(job)
        bus.emit(.jobCreated(jobID: job.id.uuidString, family: ModelFamily.flux.id))
        fluxRunner.runNext(in: fluxStore, settings: settings, coordinator: coordinator, timing: timing)
        return [job.id.uuidString]
    }

    private func enqueueKrea2(_ request: GenerateRequest) throws -> [String] {
        guard let prompt = request.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
            throw ServiceError.emptyPrompt
        }
        let (width, height) = try validatedDimensions(request, defaultWidth: settings.defaultWidth, defaultHeight: settings.defaultHeight)
        let job = Krea2Job(
            customModelRepo: request.customRepo ?? "",
            prompt: prompt,
            negativePrompt: request.negativePrompt ?? "",
            width: width,
            height: height,
            seed: request.seed ?? -1,
            seeds: batchSeeds(request),
            steps: request.steps ?? 8,
            guidance: request.guidance ?? 1.0,
            quantize: request.quantize ?? 8,
            loras: loraEntries(request),
            imagePath: request.imagePath ?? "",
            imageStrength: request.imageStrength ?? 0.75,
            board: request.board ?? "Default"
        )
        settings.recordPromptUse(prompt)
        krea2Store.add(job)
        bus.emit(.jobCreated(jobID: job.id.uuidString, family: ModelFamily.krea2.id))
        krea2Runner.runNext(in: krea2Store, settings: settings, coordinator: coordinator, timing: timing)
        return [job.id.uuidString]
    }

    private func enqueueZImage(_ request: GenerateRequest) throws -> [String] {
        guard let prompt = request.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
            throw ServiceError.emptyPrompt
        }
        let variant: FluxModelVariant = request.model == FluxModelVariant.zimage.rawValue
            ? .zimage : .zimageTurbo
        let (width, height) = try validatedDimensions(request, defaultWidth: settings.defaultWidth, defaultHeight: settings.defaultHeight)
        let job = ZImageJob(
            modelVariant: variant,
            customModelRepo: request.customRepo ?? "",
            prompt: prompt,
            negativePrompt: request.negativePrompt ?? "",
            width: width,
            height: height,
            seed: request.seed ?? -1,
            seeds: batchSeeds(request),
            steps: request.steps ?? (variant == .zimageTurbo ? 9 : 50),
            guidance: request.guidance ?? 4.0,
            quantize: request.quantize ?? variant.recommendedQuantize,
            loras: loraEntries(request),
            imagePath: request.imagePath ?? "",
            imageStrength: request.imageStrength ?? 0.75,
            board: request.board ?? "Default"
        )
        settings.recordPromptUse(prompt)
        zimageStore.add(job)
        bus.emit(.jobCreated(jobID: job.id.uuidString, family: ModelFamily.zimage.id))
        zimageRunner.runNext(in: zimageStore, settings: settings, coordinator: coordinator, timing: timing)
        return [job.id.uuidString]
    }

    // MARK: - Job lookup across families

    struct FamilyJob {
        let family: ModelFamily
        let job: any GeneratedJob
    }

    func findJob(id: UUID) -> FamilyJob? {
        if let job = fluxStore.jobs.first(where: { $0.id == id }) {
            return FamilyJob(family: .flux, job: job)
        }
        if let job = krea2Store.jobs.first(where: { $0.id == id }) {
            return FamilyJob(family: .krea2, job: job)
        }
        if let job = zimageStore.jobs.first(where: { $0.id == id }) {
            return FamilyJob(family: .zimage, job: job)
        }
        if let job = ideogramStore?.jobs.first(where: { $0.id == id }) {
            return FamilyJob(family: .ideogram4, job: job)
        }
        return nil
    }

    var ideogramStore: Ideogram4JobStore?

    // MARK: - Job lifecycle operations

    func cancel(jobID: UUID) throws {
        guard let found = findJob(id: jobID) else { throw ServiceError.jobNotFound }
        let job = found.job
        if job.status == .running {
            switch found.family {
            case .flux: fluxRunner.cancel()
            case .krea2: krea2Runner.cancel()
            case .zimage: zimageRunner.cancel()
            default: break
            }
        } else if !job.status.isTerminal {
            switch found.family {
            case .flux: fluxStore.cancelJob(job as! FluxJob)
            case .krea2: krea2Store.cancelJob(job as! Krea2Job)
            case .zimage: zimageStore.cancelJob(job as! ZImageJob)
            case .ideogram4: ideogramStore?.cancelJob(job as! Ideogram4Job)
            default: break
            }
            bus.emit(.jobCancelled(jobID: jobID.uuidString))
        }
        bus.emit(.queueChanged)
    }

    func retry(jobID: UUID) throws {
        guard let found = findJob(id: jobID) else { throw ServiceError.jobNotFound }
        let job = found.job
        switch found.family {
        case .flux: fluxStore.restart(job as! FluxJob)
        case .krea2: krea2Store.restart(job as! Krea2Job)
        case .zimage: zimageStore.restart(job as! ZImageJob)
        case .ideogram4: ideogramStore?.restart(job as! Ideogram4Job)
        default: throw ServiceError.unknownFamily(found.family.rawValue)
        }
        drainQueues()
        bus.emit(.queueChanged)
    }

    func duplicate(jobID: UUID) throws {
        guard let found = findJob(id: jobID) else { throw ServiceError.jobNotFound }
        switch found.family {
        case .flux:
            let original = found.job as! FluxJob
            let copy = FluxJob(
                model: original.model, customModelRepo: original.customModelRepo,
                customBaseModel: original.customBaseModel, prompt: original.prompt,
                negativePrompt: original.negativePrompt, width: original.width,
                height: original.height, seed: original.seed, seeds: [],
                steps: original.steps, guidance: original.guidance,
                loras: original.loras, quantize: original.quantize,
                lowRam: original.lowRam, imagePath: original.imagePath,
                imageStrength: original.imageStrength, isEditMode: original.isEditMode,
                editImagePaths: original.editImagePaths, board: original.board,
                pidDecode: original.pidDecode, pidDegradeSigma: original.pidDegradeSigma
            )
            fluxStore.add(copy)
            bus.emit(.jobCreated(jobID: copy.id.uuidString, family: ModelFamily.flux.id))
        default:
            throw ServiceError.unknownFamily(found.family.rawValue)
        }
        drainQueues()
        bus.emit(.queueChanged)
    }

    func delete(jobID: UUID, deleteFiles: Bool) throws {
        guard let found = findJob(id: jobID) else { throw ServiceError.jobNotFound }
        // Only the flux store supports deleting output files alongside the job.
        guard let fluxJob = found.job as? FluxJob else {
            switch found.family {
            case .krea2: krea2Store.remove(ids: [jobID])
            case .zimage: zimageStore.remove(ids: [jobID])
            case .ideogram4: ideogramStore?.remove(ids: [jobID])
            default: break
            }
            bus.emit(.queueChanged)
            return
        }
        fluxStore.remove(ids: [fluxJob.id], deleteFiles: deleteFiles)
        bus.emit(.queueChanged)
    }

    /// Reorder pending jobs by rewriting `createdAt` (the runners pick the
    /// oldest pending job first — FIFO by submission). Only pending jobs are
    /// touched; terminal jobs keep their timestamps.
    func reorder(order: [UUID]) throws {
        let base = Date()
        for (index, id) in order.enumerated() {
            guard let found = findJob(id: id), !found.job.status.isTerminal else { continue }
            found.job.createdAt = base.addingTimeInterval(TimeInterval(index))
        }
        saveAllStores()
        bus.emit(.queueChanged)
    }

    private func saveAllStores() {
        fluxStore.save()
        krea2Store.save()
        zimageStore.save()
        ideogramStore?.save()
    }

    /// Kick every family runner so pending jobs start as capacity frees up.
    func drainQueues() {
        fluxRunner.runNext(in: fluxStore, settings: settings, coordinator: coordinator, timing: timing)
        krea2Runner.runNext(in: krea2Store, settings: settings, coordinator: coordinator, timing: timing)
        zimageRunner.runNext(in: zimageStore, settings: settings, coordinator: coordinator, timing: timing)
    }

    // MARK: - Snapshots

    func allJobDTOs() -> [JobDTO] {
        var dtos: [JobDTO] = []
        dtos.append(contentsOf: fluxStore.jobs.map(JobDTO.init(job:)))
        dtos.append(contentsOf: krea2Store.jobs.map(JobDTO.init(job:)))
        dtos.append(contentsOf: zimageStore.jobs.map(JobDTO.init(job:)))
        if let ideogramStore {
            dtos.append(contentsOf: ideogramStore.jobs.map(JobDTO.init(job:)))
        }
        return dtos
    }

    func pendingCount() -> Int {
        fluxStore.pendingJobs.count + krea2Store.pendingJobs.count + zimageStore.pendingJobs.count
            + (ideogramStore?.pendingJobs.count ?? 0)
    }
}

import Foundation

/// JSON projection of a `GeneratedJob` for the remote API. Common fields come
/// from the protocol; family-specific input fields are added by casting to the
/// concrete job type. Nothing here mutates app state.
struct JobDTO: Encodable {
    let id: String
    let family: String
    let status: String
    let statusMessage: String?
    let statusLine: String?
    let stepTiming: String?
    let prompt: String?
    let negativePrompt: String?
    let model: String?
    let seed: Int?
    let seeds: [Int]?
    let resolvedSeed: Int?
    let width: Int?
    let height: Int?
    let steps: Int?
    let guidance: Double?
    let quantize: Int?
    let lowRam: Bool?
    let imageStrength: Double?
    let hasImageInput: Bool
    let currentStep: Int
    let totalSteps: Int
    let progress: Double
    let outputPath: String?
    let outputPaths: [String]
    let board: String?
    let createdAt: Date
    let startedAt: Date?
    let completedAt: Date?
    let previewURL: String?

    @MainActor
    init(job: some GeneratedJob) {
        id = job.id.uuidString
        seed = job.seed
        seeds = job.seeds.isEmpty ? nil : job.seeds
        resolvedSeed = job.resolvedSeed
        width = job.width
        height = job.height
        currentStep = job.currentStep
        totalSteps = job.totalSteps
        progress = job.totalSteps > 0 ? Double(job.currentStep) / Double(job.totalSteps) : 0
        outputPath = job.outputPath
        outputPaths = job.outputPaths
        createdAt = job.createdAt
        startedAt = job.startedAt
        completedAt = job.completedAt
        statusLine = job.statusLine.isEmpty ? nil : job.statusLine
        stepTiming = job.stepTiming
        previewURL = "/api/v1/jobs/\(id)/preview"

        switch job.status {
        case .pending:
            status = "pending"
            statusMessage = nil
        case .running:
            status = "running"
            statusMessage = nil
        case .completed:
            status = "completed"
            statusMessage = nil
        case .cancelled:
            status = "cancelled"
            statusMessage = nil
        case .failed(let message):
            status = "failed"
            statusMessage = message
        }

        if let flux = job as? FluxJob {
            family = ModelFamily.flux.id
            prompt = flux.prompt
            negativePrompt = flux.negativePrompt.isEmpty ? nil : flux.negativePrompt
            model = flux.model.rawValue
            steps = flux.steps
            guidance = flux.guidance
            quantize = flux.quantize
            lowRam = flux.lowRam
            imageStrength = flux.imagePath.isEmpty ? nil : flux.imageStrength
            board = flux.board
            hasImageInput = !flux.imagePath.isEmpty
        } else if let krea2 = job as? Krea2Job {
            family = ModelFamily.krea2.id
            prompt = krea2.prompt
            negativePrompt = krea2.negativePrompt.isEmpty ? nil : krea2.negativePrompt
            model = krea2.customModelRepo.isEmpty ? "krea2-turbo" : krea2.customModelRepo
            steps = krea2.steps
            guidance = krea2.guidance
            quantize = krea2.quantize
            lowRam = nil
            imageStrength = krea2.imagePath.isEmpty ? nil : krea2.imageStrength
            board = krea2.board
            hasImageInput = !krea2.imagePath.isEmpty
        } else if let zimage = job as? ZImageJob {
            family = ModelFamily.zimage.id
            prompt = zimage.prompt
            negativePrompt = zimage.negativePrompt.isEmpty ? nil : zimage.negativePrompt
            model = zimage.modelVariant.rawValue
            steps = zimage.steps
            guidance = zimage.guidance
            quantize = zimage.quantize
            lowRam = nil
            imageStrength = zimage.imagePath.isEmpty ? nil : zimage.imageStrength
            board = zimage.board
            hasImageInput = !zimage.imagePath.isEmpty
        } else if let ideogram = job as? Ideogram4Job {
            family = ModelFamily.ideogram4.id
            prompt = ideogram.usePlainPrompt ? ideogram.plainPrompt : nil
            negativePrompt = nil
            model = ideogram.customModelRepo.isEmpty ? "ideogram4" : ideogram.customModelRepo
            steps = nil
            guidance = nil
            quantize = ideogram.quantize
            lowRam = ideogram.lowRam
            imageStrength = nil
            board = ideogram.board
            hasImageInput = false
        } else {
            family = "unknown"
            prompt = nil
            negativePrompt = nil
            model = nil
            steps = nil
            guidance = nil
            quantize = nil
            lowRam = nil
            imageStrength = nil
            board = nil
            hasImageInput = false
        }
    }
}

/// JSON projection of a gallery item for the remote API.
struct GalleryItemDTO: Encodable {
    let id: String
    let url: String
    let thumbnailURL: String
    let filename: String
    let board: String
    let family: String
    let modifiedAt: Date
    let flag: String?
    let rating: Int
    let metadata: ImageMetadataDTO?

    @MainActor
    init(item: GalleryItem) {
        id = item.id.uuidString
        url = "/api/v1/images/\(id)"
        thumbnailURL = "/api/v1/images/\(id)?thumbnail=1"
        filename = item.filename
        board = item.board
        family = item.modelFamily.id
        modifiedAt = item.modifiedAt
        switch item.flag {
        case .pick: flag = "pick"
        case .reject: flag = "reject"
        case nil: flag = nil
        }
        rating = item.rating
        metadata = ImageMetadataDTO(sidecar: item.metadata)
    }
}

struct ImageMetadataDTO: Encodable {
    let prompt: String?
    let negativePrompt: String?
    let model: String?
    let seed: Int?
    let steps: Int?
    let guidance: Double?
    let width: Int?
    let height: Int?
    let quantize: Int?
    let loras: [String]

    init(sidecar: GenerationMetadata?) {
        guard let sidecar else {
            prompt = nil
            negativePrompt = nil
            model = nil
            seed = nil
            steps = nil
            guidance = nil
            width = nil
            height = nil
            quantize = nil
            loras = []
            return
        }
        prompt = sidecar.prompt
        negativePrompt = sidecar.negativePrompt.isEmpty ? nil : sidecar.negativePrompt
        model = sidecar.customModelRepo.isEmpty ? sidecar.model.rawValue : sidecar.customModelRepo
        seed = sidecar.seed
        steps = sidecar.steps
        guidance = sidecar.guidance
        width = sidecar.width
        height = sidecar.height
        quantize = sidecar.quantize
        loras = sidecar.loras.map(\.path)
    }
}

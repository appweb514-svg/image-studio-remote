import AppKit
import Foundation

/// Owns the embedded remote-access server: lifecycle, auth and HTTP routing.
///
/// Routing is a pure dispatcher: every handler calls into `GenerationService`
/// (or reads existing stores directly) — mflux is never touched from here.
@MainActor
@Observable
final class RemoteAccessStore {
    // MARK: - Dependencies

    private let settings: AppSettings
    private let service: GenerationService
    private let bus: RemoteAccessEventBus
    let superscale: SuperscaleService
    private var auth = RemoteAuthService()
    private var monitor: ProgressMonitor?
    private var server: RemoteHTTPServer?

    // MARK: - Observable state (drives the Settings > Remote Access UI)

    private(set) var isRunning = false
    private(set) var startError: String?
    private(set) var connectedClients = 0
    private(set) var lastActivity: Date?

    // MARK: - Config (backed by AppSettings)

    var isEnabled: Bool {
        get { settings.remoteAccessEnabled }
        set {
            settings.remoteAccessEnabled = newValue
            Task { await syncServerState() }
        }
    }

    var port: Int {
        get { settings.remoteAccessPort }
        set { settings.remoteAccessPort = newValue }
    }

    var allowLAN: Bool {
        get { settings.remoteAccessAllowLAN }
        set {
            settings.remoteAccessAllowLAN = newValue
            Task { await syncServerState() }
        }
    }

    var requireAuth: Bool {
        get { settings.remoteAccessRequireAuth }
        set {
            settings.remoteAccessRequireAuth = newValue
            if newValue { auth.endAllSessions() }
            Task { await syncServerState() }
        }
    }

    // MARK: - Access token (Keychain-backed)

    static let tokenKey = "remote_access_token"

    var token: String {
        let existing = KeychainHelper.get(Self.tokenKey)
        if !existing.isEmpty { return existing }
        let generated = RemoteAuthService.randomToken()
        KeychainHelper.set(generated, key: Self.tokenKey)
        return generated
    }

    func regenerateToken() {
        KeychainHelper.set(RemoteAuthService.randomToken(), key: Self.tokenKey)
        auth.endAllSessions()
    }

    // MARK: - URLs for the Settings UI

    var localURL: String { "http://127.0.0.1:\(port)" }
    var networkURL: String { "http://\(Self.hostName()):\(port)" }

    static func hostName() -> String {
        if let name = Host.current().localizedName {
            return name.replacingOccurrences(of: " ", with: "-").lowercased() + ".local"
        }
        return "localhost"
    }

    init(
        settings: AppSettings,
        service: GenerationService,
        bus: RemoteAccessEventBus
    ) {
        self.settings = settings
        self.service = service
        self.bus = bus
        self.superscale = SuperscaleService(settings: settings, bus: bus)
        monitor = ProgressMonitor(service: service, bus: bus)
    }

    func startIfNeeded() {
        if isEnabled { startServer() }
    }

    func syncServerState() {
        if isEnabled {
            startServer()
        } else {
            stopServer()
        }
    }

    private func startServer() {
        guard !isRunning else { return }
        let store = self
        let httpServer = RemoteHTTPServer(
            port: UInt16(port),
            bindAllInterfaces: allowLAN
        ) { request in
            await store.handle(request)
        }
        do {
            try httpServer.start()
            server = httpServer
            isRunning = true
            startError = nil
            monitor?.start()
        } catch {
            startError = "Port \(port) indisponible : \(error.localizedDescription)"
            isRunning = false
        }
    }

    private func stopServer() {
        server?.stop()
        server = nil
        isRunning = false
        monitor?.stop()
        auth.endAllSessions()
    }

    // MARK: - HTTP entry point

    nonisolated func handle(_ request: HTTPRequest) async -> HTTPResponse {
        await route(request)
    }

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        lastActivity = Date()

        // CORS: same-origin by default. Origins explicitly configured for the
        // "external Web UI" mode get CORS headers; everything else is denied.
        if request.method == "OPTIONS" {
            return preflightResponse(for: request)
        }

        let path = request.path
        let apiPath = "/api/v1"

        if path.hasPrefix(apiPath) {
            var response = await routeAPI(request, apiPath: apiPath)
            corsHeaders(for: request, into: &response)
            return response
        }

        // Static Web UI — served without auth so the login screen loads.
        return serveStatic(path)
    }

    // MARK: - API routing

    private func routeAPI(_ request: HTTPRequest, apiPath: String) async -> HTTPResponse {
        let path = String(request.path.dropFirst(apiPath.count))
        let method = request.method

        if path == "/auth/login", method == "POST" {
            return login(request)
        }
        if path == "/auth/logout", method == "POST" {
            auth.endSession(request.cookies[RemoteAuthCookie.name])
            var response = HTTPResponse.json(["ok": true])
            response.headers["Set-Cookie"] = "\(RemoteAuthCookie.name)=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"
            return response
        }

        // Auth gate for everything else.
        if settings.remoteAccessRequireAuth, !isAuthorized(request) {
            return .unauthorized()
        }

        switch (method, path) {
        case ("GET", "/status"):
            return statusEndpoint()
        case ("GET", "/capabilities"):
            return capabilities()
        case ("GET", "/models"):
            return models()
        case ("GET", "/queue"):
            return queue()
        case ("POST", "/generate"):
            return generate(request)
        case ("GET", "/history"):
            return history(request)
        case ("GET", "/events"):
            return events()
        case ("GET", "/presets"):
            return presets()
        default:
            break
        }

        // Path-parameterized routes.
        let segments = path.split(separator: "/").map(String.init)
        if segments.first == "jobs", segments.count >= 2, let id = UUID(uuidString: segments[1]) {
            switch (method, segments.count == 2 ? "" : segments[2]) {
            case ("GET", ""):
                if let job = service.findJob(id: id) {
                    return .json(JobDTO(job: job.job))
                }
                return .fileNotFound()
            case ("POST", "cancel"):
                return run { try service.cancel(jobID: id) }
            case ("POST", "retry"):
                return run { try service.retry(jobID: id) }
            case ("POST", "duplicate"):
                return run { try service.duplicate(jobID: id) }
            case ("DELETE", ""):
                return run { try service.delete(jobID: id, deleteFiles: false) }
            case ("GET", "preview"):
                return jobPreview(id: id)
            default:
                return .fileNotFound()
            }
        }

        if segments.first == "images", segments.count == 2, let id = UUID(uuidString: segments[1]) {
            return galleryImage(id: id, thumbnail: request.query["thumbnail"] == "1")
        }

        if segments.first == "gallery", segments.count == 4 {
            if let id = UUID(uuidString: segments[1]) {
                switch (method, segments[2]) {
                case ("POST", "flag"):
                    return galleryFlag(id: id, request: request)
                case ("POST", "rating"):
                    return galleryRating(id: id, request: request)
                case ("POST", "variation"), ("POST", "reuse"):
                    return galleryReuse(id: id, variation: segments[2] == "variation")
                default:
                    return .fileNotFound()
                }
            }
        }

        if segments.first == "queue", segments.count == 2, segments[1] == "reorder", method == "PATCH" {
            return reorder(request)
        }

        if segments.first == "uploads", method == "POST" {
            return upload(request)
        }

        // Upscale (Superscale / Real-ESRGAN).
        if segments.first == "upscale" {
            return routeUpscale(request, segments: Array(segments.dropFirst()))
        }

        return .fileNotFound()
    }

    private func routeUpscale(_ request: HTTPRequest, segments: [String]) -> HTTPResponse {
        switch (request.method, segments.first) {
        case ("GET", "models"):
            return .json(superscale.modelStatuses())

        case ("POST", "download") where segments.count == 2:
            let name = segments[1]
            Task { @MainActor in
                try? await superscale.downloadModel(named: name)
            }
            return .json(["ok": true])

        case ("GET", "recommendations"):
            var width: Int?
            var height: Int?
            if let imageID = request.query["image_id"].flatMap({ UUID(uuidString: $0) }),
               let item = service.gallery.items.first(where: { $0.id == imageID }) {
                guard let source = NSImage(contentsOf: item.url) else {
                    return .jsonError(404, "image illisible")
                }
                width = Int(source.size.width)
                height = Int(source.size.height)
            } else if let w = request.query["width"].flatMap(Int.init),
                      let h = request.query["height"].flatMap(Int.init) {
                width = w
                height = h
            }
            guard let width, let height else {
                return .jsonError(400, "image_id ou width+height requis")
            }
            let recs = superscale.recommendations(
                sourceWidth: Int(width),
                sourceHeight: Int(height),
                modelName: request.query["model"]
            )
            return .json(recs)

        case ("POST", "jobs"):
            return upscaleStart(request)

        case ("GET", "jobs") where segments.count == 1:
            return .json(superscale.recentJobs().map(UpscaleJobDTO.init(from:)))

        default:
            if segments.first == "jobs", segments.count == 2,
               let id = UUID(uuidString: segments[1]) {
                guard let job = superscale.job(id: id) else { return .fileNotFound() }
                return .json(UpscaleJobDTO(from: job))
            }
            return .fileNotFound()
        }
    }

    struct UpscaleJobDTO: Encodable {
        let id: String
        let status: String
        let model: String
        let input_path: String
        let output_path: String?
        let phase: String
        let tiles_done: Int
        let tiles_total: Int
        let error: String?
        let created_at: Date

        init(from job: SuperscaleService.UpscaleJob) {
            id = job.id.uuidString
            status = job.status.rawValue
            model = job.modelName
            input_path = job.inputPath
            output_path = job.outputPath
            phase = job.phase
            tiles_done = job.tilesDone
            tiles_total = job.tilesTotal
            error = job.error
            created_at = job.createdAt
        }
    }

    private func upscaleStart(_ request: HTTPRequest) -> HTTPResponse {
        struct UpscaleBody: Decodable {
            var image_id: String?
            var path: String?
            var model: String?
            var scale: Double?
            var target_width: Int?
            var target_height: Int?
            var stretch: Bool?
            var face_enhance: Bool?
        }
        guard let body = try? JSONDecoder().decode(UpscaleBody.self, from: request.body) else {
            return .jsonError(400, "corps invalide")
        }

        var inputURL: URL?
        if let imageID = body.image_id.flatMap({ UUID(uuidString: $0) }),
           let item = service.gallery.items.first(where: { $0.id == imageID }) {
            inputURL = item.url
        } else if let path = body.path, !path.isEmpty {
            // Only allow reading from the app-controlled uploads directory and
            // the output directory — never arbitrary client paths.
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            let allowedPrefixes = [
                Self.uploadsDir.standardizedFileURL.path + "/",
                URL(fileURLWithPath: service.settings.outputDir).standardizedFileURL.path + "/",
            ]
            if allowedPrefixes.contains(where: { standardized.hasPrefix($0) }) {
                inputURL = URL(fileURLWithPath: standardized)
            }
        }
        guard let inputURL, FileManager.default.fileExists(atPath: inputURL.path) else {
            return .jsonError(400, "image_id (galerie) ou path (uploads/output) requis")
        }
        if let scale = body.scale, !(1.1...8.0).contains(scale) {
            return .jsonError(400, "scale hors limites (1.1–8)")
        }

        let jobID = superscale.enqueue(
            inputURL: inputURL,
            modelName: body.model,
            requestedScale: body.scale,
            targetWidth: body.target_width,
            targetHeight: body.target_height,
            stretch: body.stretch ?? false,
            faceEnhance: body.face_enhance
        )
        return .json(["job_id": jobID.uuidString])
    }

    private func run(_ operation: () throws -> Void) -> HTTPResponse {
        do {
            try operation()
            return .json(["ok": true])
        } catch {
            return .jsonError(400, error.localizedDescription)
        }
    }

    // MARK: - Auth

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        if auth.validateSession(request.cookies[RemoteAuthCookie.name]) {
            return true
        }
        // Programmatic clients (external Web UI mode) use a bearer token.
        if let authorization = request.header("authorization"),
           authorization.hasPrefix("Bearer "),
           RemoteAuthService.matchesToken(
               String(authorization.dropFirst(7)),
               expected: token
           ) {
            return true
        }
        return false
    }

    private func login(_ request: HTTPRequest) -> HTTPResponse {
        guard auth.checkRateLimit(client: request.remoteAddress) else {
            return .tooManyRequests()
        }
        struct LoginBody: Decodable { var token: String? }
        let body = try? JSONDecoder().decode(LoginBody.self, from: request.body)
        guard let presented = body?.token, !presented.isEmpty else {
            auth.recordFailedAttempt(client: request.remoteAddress)
            return .jsonError(401, "token requis")
        }
        guard RemoteAuthService.matchesToken(presented, expected: token) else {
            auth.recordFailedAttempt(client: request.remoteAddress)
            return .jsonError(401, "token invalide")
        }
        auth.clearFailures(client: request.remoteAddress)
        let session = auth.createSession()
        var response = HTTPResponse.json(["ok": true])
        response.headers["Set-Cookie"] =
            "\(RemoteAuthCookie.name)=\(session); Path=/; HttpOnly; SameSite=Lax; Max-Age=\(Int(RemoteAuthService.sessionTTL))"
        return response
    }

    private func preflightResponse(for request: HTTPRequest) -> HTTPResponse {
        guard let origin = request.header("origin"), allowedOrigins.contains(origin) else {
            return HTTPResponse(status: 204, headers: [:], body: .empty)
        }
        return HTTPResponse(
            status: 204,
            headers: [
                "Access-Control-Allow-Origin": origin,
                "Access-Control-Allow-Methods": "GET, POST, PATCH, DELETE, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type, Authorization",
                "Access-Control-Max-Age": "600",
            ],
            body: .empty
        )
    }

    private var allowedOrigins: Set<String> {
        // External-Web-UI mode: origins are configured via user defaults; empty
        // by default (pure same-origin). Keep strict.
        Set(UserDefaults.standard.stringArray(forKey: "remoteAccessAllowedOrigins") ?? [])
    }

    private func corsHeaders(for request: HTTPRequest, into response: inout HTTPResponse) {
        guard let origin = request.header("origin"), allowedOrigins.contains(origin) else { return }
        response.headers["Access-Control-Allow-Origin"] = origin
        response.headers["Vary"] = "Origin"
    }

    // MARK: - GET endpoints

    private func statusEndpoint() -> HTTPResponse {
        let driver = service.fluxRunner.driver
        let snapshot = SystemInfoSnapshot.current(
            queueLength: service.pendingCount(),
            loadedModel: driver?.loadedModelLabel,
            loadedModelMemoryGB: driver?.loadedMemoryGB,
            mfluxVersion: nil
        )
        return .json(StatusPayload(
            app: "MLXBits Image Studio",
            remoteAccess: RemoteStatus(
                isRunning: isRunning,
                allowLAN: allowLAN,
                requireAuth: requireAuth,
                connectedClients: bus.subscriberCount
            ),
            system: snapshot,
            queue: QueueSummary(
                pending: service.pendingCount(),
                runningFlux: service.fluxStore.isRunning,
                runningKrea2: service.krea2Store.isRunning,
                runningZImage: service.zimageStore.isRunning
            )
        ))
    }

    struct StatusPayload: Encodable {
        let app: String
        let remoteAccess: RemoteStatus
        let system: SystemInfoSnapshot
        let queue: QueueSummary
    }

    struct RemoteStatus: Encodable {
        let isRunning: Bool
        let allowLAN: Bool
        let requireAuth: Bool
        let connectedClients: Int
    }

    struct QueueSummary: Encodable {
        let pending: Int
        let runningFlux: Bool
        let runningKrea2: Bool
        let runningZImage: Bool
    }

    private func capabilities() -> HTTPResponse {
        let variants = FluxModelVariant.allModels.map { variant -> CapabilityModel in
            CapabilityModel(
                id: variant.rawValue,
                family: variant.family.id,
                displayName: variant.displayName,
                isDistilled: variant.isDistilled,
                defaultSteps: variant.defaultSteps,
                defaultGuidance: variant.defaultGuidance,
                supportsNegativePrompt: variant.supportsNegativePrompt,
                recommendedQuantize: variant.recommendedQuantize,
                approximateSizeGB: variant.approximateSizeGB(quantize: variant.recommendedQuantize)
            )
        }
        return .json(CapabilitiesPayload(
            families: ModelFamily.generative.map { family in
                FamilyCapability(
                    id: family.id,
                    displayName: family.rawValue,
                    webEnqueue: family != .ideogram4,
                    supportsEdit: family == .flux,
                    maxEditImages: family == .flux ? 4 : 0
                )
            },
            models: variants,
            quantizeOptions: [0, 3, 4, 6, 8],
            batchLimits: BatchLimits(min: 1, max: 16),
            dimensionConstraints: DimensionConstraintsPayload(
                minEdge: 64, maxEdge: 4096, multipleOf: 8
            ),
            timingEstimateAvailable: true
        ))
    }

    struct CapabilitiesPayload: Encodable {
        let families: [FamilyCapability]
        let models: [CapabilityModel]
        let quantizeOptions: [Int]
        let batchLimits: BatchLimits
        let dimensionConstraints: DimensionConstraintsPayload
        let timingEstimateAvailable: Bool
    }

    struct FamilyCapability: Encodable {
        let id: String
        let displayName: String
        let webEnqueue: Bool
        let supportsEdit: Bool
        let maxEditImages: Int
    }

    struct CapabilityModel: Encodable {
        let id: String
        let family: String
        let displayName: String
        let isDistilled: Bool
        let defaultSteps: Int
        let defaultGuidance: Double
        let supportsNegativePrompt: Bool
        let recommendedQuantize: Int
        let approximateSizeGB: Double
    }

    struct BatchLimits: Encodable {
        let min: Int
        let max: Int
    }

    struct DimensionConstraintsPayload: Encodable {
        let minEdge: Int
        let maxEdge: Int
        let multipleOf: Int
    }

    private func models() -> HTTPResponse {
        struct ModelStatus: Encodable {
            let id: String
            let displayName: String
            let family: String
            let onDiskQ8: Bool
            let onDiskQ4: Bool
            let sizeGBQ8: Double
            let sizeGBQ4: Double
            let repoURL: String?
        }
        let statuses = FluxModelVariant.allModels.filter { $0 != .custom }.map { variant in
            ModelStatus(
                id: variant.rawValue,
                displayName: variant.displayName,
                family: variant.family.id,
                onDiskQ8: variant.isOnDisk(quantize: 8),
                onDiskQ4: variant.isOnDisk(quantize: 4),
                sizeGBQ8: variant.approximateSizeGB(quantize: 8),
                sizeGBQ4: variant.approximateSizeGB(quantize: 4),
                repoURL: variant.hfRepoURL(quantize: 8)?.absoluteString
            )
        }
        return .json(statuses)
    }

    private func queue() -> HTTPResponse {
        .json(service.allJobDTOs())
    }

    private func generate(_ request: HTTPRequest) -> HTTPResponse {
        do {
            let body = try JSONDecoder().decode(GenerationService.GenerateRequest.self, from: request.body)
            try service.enqueue(body)
            return .json(["ok": true])
        } catch let error as DecodingError {
            return .jsonError(400, "requête invalide: \(error.localizedDescription)")
        } catch {
            return .jsonError(400, error.localizedDescription)
        }
    }

    private func history(_ request: HTTPRequest) -> HTTPResponse {
        service.gallery.scan(outputDir: service.settings.outputDir)
        let items = service.gallery.items.map(GalleryItemDTO.init(item:))
        return .json(items)
    }

    private func presets() -> HTTPResponse {
        struct Presets: Encodable {
            struct Template: Encodable {
                let id: String
                let name: String
                let positive: String
                let negative: String
            }

            struct Default: Encodable {
                let model: String
                let steps: Int?
                let guidance: Double?
                let width: Int?
                let height: Int?
                let quantize: Int?
                let lowRam: Bool?
            }

            let templates: [Template]
            let modelDefaults: [Default]
        }
        let templates = settings.customTemplates.map {
            Presets.Template(
                id: $0.id.uuidString,
                name: $0.name,
                positive: $0.positiveTemplate,
                negative: $0.negativeTemplate
            )
        }
        let defaults = settings.modelDefaults.map { key, value in
            Presets.Default(
                model: key,
                steps: value.steps,
                guidance: value.guidance,
                width: value.width,
                height: value.height,
                quantize: value.quantize,
                lowRam: value.lowRam
            )
        }
        return .json(Presets(templates: templates, modelDefaults: defaults))
    }

    // MARK: - SSE

    private func events() -> HTTPResponse {
        let stream = bus.subscribe()
        return HTTPResponse(
            status: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: .stream(stream)
        )
    }

    // MARK: - Job preview + gallery images

    /// Live preview while running (downscaled stepwise frames); the full-size
    /// final image once the job completed (the web UI fetches the result here,
    /// since `output_paths` are local filesystem paths).
    private func jobPreview(id: UUID) -> HTTPResponse {
        guard let found = service.findJob(id: id) else {
            return .fileNotFound()
        }
        if found.job.status == .completed {
            let finalPath = found.job.outputPaths.last ?? found.job.outputPath
            guard let finalPath, let data = try? Data(contentsOf: URL(fileURLWithPath: finalPath)) else {
                return .fileNotFound()
            }
            return .data(data, contentType: "image/png")
        }
        guard let path = found.job.latestStepwisePath,
              let jpeg = ProgressMonitor.downscaledJPEG(path: path) else {
            return .jsonError(404, "preview pas encore disponible")
        }
        return .data(jpeg, contentType: "image/jpeg")
    }

    private func galleryImage(id: UUID, thumbnail: Bool) -> HTTPResponse {
        guard let item = service.gallery.items.first(where: { $0.id == id }) else {
            return .fileNotFound()
        }
        let url = item.url
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .fileNotFound()
        }
        if thumbnail {
            if let cached = ThumbnailCache.read(for: item.path) {
                return .data(cached, contentType: "image/jpeg", cacheSeconds: 300)
            }
            if let generated = ThumbnailCache.makeThumbnailData(forSourcePath: item.path) {
                ThumbnailCache.store(data: generated, for: item.path)
                return .data(generated, contentType: "image/jpeg", cacheSeconds: 300)
            }
            return .fileNotFound()
        }
        guard let data = try? Data(contentsOf: url) else {
            return .jsonError(500, "lecture impossible")
        }
        return .data(data, contentType: Self.mimeType(for: url), cacheSeconds: 300)
    }

    private func galleryFlag(id: UUID, request: HTTPRequest) -> HTTPResponse {
        struct FlagBody: Decodable { var flag: String? }
        guard let item = service.gallery.items.first(where: { $0.id == id }) else {
            return .fileNotFound()
        }
        let body = try? JSONDecoder().decode(FlagBody.self, from: request.body)
        let flag: PickFlag?
        switch body?.flag {
        case "pick": flag = .pick
        case "reject": flag = .reject
        default: flag = nil
        }
        service.gallery.setFlag(flag, for: item)
        struct FlagOK: Encodable { let ok: Bool; let flag: String }
        return .json(FlagOK(ok: true, flag: body?.flag ?? "none"))
    }

    private func galleryRating(id: UUID, request: HTTPRequest) -> HTTPResponse {
        struct RatingBody: Decodable { var rating: Int? }
        guard let item = service.gallery.items.first(where: { $0.id == id }) else {
            return .fileNotFound()
        }
        let body = try? JSONDecoder().decode(RatingBody.self, from: request.body)
        let rating = min(max(body?.rating ?? 0, 0), 5)
        service.gallery.setRating(rating, for: item)
        struct RatingOK: Encodable { let ok: Bool; let rating: Int }
        return .json(RatingOK(ok: true, rating: rating))
    }

    /// "Reuse settings" / "Generate variation" from a gallery item.
    private func galleryReuse(id: UUID, variation: Bool) -> HTTPResponse {
        guard let item = service.gallery.items.first(where: { $0.id == id }),
              let metadata = item.metadata else {
            return .jsonError(404, "métadonnées indisponibles")
        }
        var request = GenerationService.GenerateRequest()
        request.family = ModelFamily.flux.id
        request.model = metadata.customModelRepo.isEmpty ? metadata.model.rawValue : nil
        request.customRepo = metadata.customModelRepo.isEmpty ? nil : metadata.customModelRepo
        request.prompt = metadata.prompt
        request.negativePrompt = metadata.negativePrompt
        request.width = metadata.width
        request.height = metadata.height
        request.steps = metadata.steps
        request.guidance = metadata.guidance
        request.quantize = metadata.quantize
        if variation { request.seed = Int.random(in: 0...Int.max) }
        do {
            try service.enqueue(request)
            return .json(["ok": true])
        } catch {
            return .jsonError(400, error.localizedDescription)
        }
    }

    private func reorder(_ request: HTTPRequest) -> HTTPResponse {
        struct ReorderBody: Decodable { var order: [String]? }
        guard let body = try? JSONDecoder().decode(ReorderBody.self, from: request.body),
              let order = body.order else {
            return .jsonError(400, "order requis")
        }
        let ids = order.compactMap { UUID(uuidString: $0) }
        try? service.reorder(order: ids)
        return .json(["ok": true])
    }

    // MARK: - Uploads (img2img from phone/tablet)

    private static let uploadsDir: URL = {
        let dir = JobStore.appSupportURL.appendingPathComponent("RemoteAccessUploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let allowedUploadExtensions = ["png", "jpg", "jpeg", "webp"]
    private static let maxUploadBytes = 20 * 1024 * 1024

    private func upload(_ request: HTTPRequest) -> HTTPResponse {
        struct UploadBody: Decodable {
            var filename: String?
            var mime: String?
            var data_base64: String?
        }
        guard let body = try? JSONDecoder().decode(UploadBody.self, from: request.body),
              let base64 = body.data_base64, !base64.isEmpty else {
            return .jsonError(400, "data_base64 requis")
        }
        guard base64.count < Self.maxUploadBytes / 3 * 4 else {
            return .jsonError(413, "fichier trop volumineux (max 20 Mo)")
        }
        guard let data = Data(base64Encoded: base64) else {
            return .jsonError(400, "base64 invalide")
        }

        // Extension from the declared mime type only — never trust the
        // client-supplied filename for path construction.
        let mime = (body.mime ?? "").lowercased()
        let ext: String
        switch mime {
        case "image/png": ext = "png"
        case "image/jpeg", "image/jpg": ext = "jpg"
        case "image/webp": ext = "webp"
        default:
            return .jsonError(415, "type non supporté (png/jpeg/webp)")
        }

        // Content sniffing: verify magic bytes match the declared type.
        guard Self.magicMatches(data: data, ext: ext) else {
            return .jsonError(415, "contenu incompatible avec le type déclaré")
        }

        let destination = Self.uploadsDir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            return .jsonError(500, "écriture impossible")
        }
        return .json(["path": destination.path])
    }

    private static func magicMatches(data: Data, ext: String) -> Bool {
        guard data.count > 12 else { return false }
        let bytes = [UInt8](data.prefix(12))
        func startsWith(_ prefix: [UInt8]) -> Bool {
            Array(bytes.prefix(prefix.count)) == prefix
        }
        switch ext {
        case "png":
            return startsWith([0x89, 0x50, 0x4E, 0x47])
        case "jpg":
            return startsWith([0xFF, 0xD8, 0xFF])
        case "webp":
            return startsWith(Array("RIFF".utf8)) && Array(bytes[8...11]) == Array("WEBP".utf8)
        default:
            return false
        }
    }

    // MARK: - Static files

    private func serveStatic(_ path: String) -> HTTPResponse {
        guard let webRoot = Self.webRootURL() else {
            return .html(Self.fallbackHTML)
        }
        var relative = path
        if relative == "/" { relative = "/index.html" }
        let fileURL = webRoot.appendingPathComponent(relative.trimmingCharacters(in: CharacterSet(charactersIn: "/")))

        // Path traversal guard: resolved file must stay under the web root.
        let standardized = fileURL.standardizedFileURL.path
        guard standardized.hasPrefix(webRoot.standardizedFileURL.path + "/") else {
            return .fileNotFound()
        }

        guard FileManager.default.fileExists(atPath: standardized),
              let data = try? Data(contentsOf: URL(fileURLWithPath: standardized)) else {
            // SPA fallback: client-side router owns unknown paths.
            let indexURL = webRoot.appendingPathComponent("index.html")
            if let index = try? Data(contentsOf: indexURL) {
                return .data(index, contentType: "text/html; charset=utf-8")
            }
            return .html(Self.fallbackHTML)
        }
        return .data(data, contentType: Self.mimeType(for: fileURL), cacheSeconds: relative.hasPrefix("/assets/") ? 3600 : 0)
    }

    nonisolated static func webRootURL() -> URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("webui_dist") {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: bundled.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return bundled
            }
        }
        // Development fallback (running from source checkout).
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // RemoteAccess
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("webui/dist")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: dev.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return dev
        }
        return nil
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json": "application/json"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "webp": "image/webp"
        case "svg": "image/svg+xml"
        case "ico": "image/x-icon"
        case "woff2": "font/woff2"
        case "woff": "font/woff"
        case "map": "application/json"
        default: "application/octet-stream"
        }
    }

    private static let fallbackHTML = """
    <!doctype html><html><head><meta charset="utf-8"><title>MLXBits Image Studio</title></head>
    <body style="font-family:-apple-system,sans-serif;background:#111;color:#eee;display:grid;place-items:center;height:100vh">
    <div style="text-align:center">
      <h1>MLXBits Image Studio</h1>
      <p>Le frontend Web n'est pas encore compilé dans le bundle.<br>Lancez <code>webui/build-release.sh</code> puis reconstruisez l'app.</p>
    </div></body></html>
    """
}

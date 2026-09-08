import SwiftUI

@main
struct MLXBitsImageStudioApp: App {
    @State private var settings: AppSettings
    @State private var store = JobStore()
    @State private var gallery = GalleryStore()
    @State private var runner: FluxJobRunner
    @State private var driverController: MfluxDriverController
    @State private var ideogram4Store = Ideogram4JobStore()
    @State private var ideogram4Runner = Ideogram4JobRunner()
    @State private var krea2Store = Krea2JobStore()
    @State private var krea2Runner = Krea2JobRunner()
    @State private var zimageStore = ZImageJobStore()
    @State private var zimageRunner = ZImageJobRunner()
    @State private var seedVR2Store = SeedVR2JobStore()
    @State private var seedVR2Runner = SeedVR2JobRunner()
    @State private var coordinator = GenerationCoordinator()
    @State private var timing = TimingStore()
    @State private var loraLibrary = LoraLibraryStore()
    @State private var updateChecker = UpdateChecker()
    @State private var backendModels = BackendModelStore()
    @State private var remoteEventBus = RemoteAccessEventBus()
    @State private var generationService: GenerationService
    @State private var remoteAccess: RemoteAccessStore

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
                .environment(store)
                .environment(gallery)
                .environment(runner)
                .environment(ideogram4Store)
                .environment(ideogram4Runner)
                .environment(krea2Store)
                .environment(krea2Runner)
                .environment(zimageStore)
                .environment(zimageRunner)
                .environment(seedVR2Store)
                .environment(seedVR2Runner)
                .environment(coordinator)
                .environment(timing)
                .environment(driverController)
                .environment(loraLibrary)
                .environment(updateChecker)
                .environment(backendModels)
                .environment(remoteAccess)
                .frame(minWidth: 900, minHeight: 600)
                // Launch-time update check; drives the toolbar badge when a newer
                // GitHub release exists. Coalesced so multiple windows check once.
                .task { await updateChecker.check() }
                // Starts the embedded remote-access server when enabled.
                .task { remoteAccess.startIfNeeded() }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            AboutCommands()
        }

        Window("About MLXBits Image Studio", id: AboutCommands.windowID) {
            AboutView()
                .environment(updateChecker)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environment(settings)
                .environment(gallery)
                .environment(driverController)
                .environment(loraLibrary)
                .environment(remoteAccess)
        }
    }

    init() {
        let settings = AppSettings()
        let driver = MfluxDriverController(settings: settings)
        let runner = FluxJobRunner()
        runner.driver = driver
        _settings = State(initialValue: settings)
        _driverController = State(initialValue: driver)
        _runner = State(initialValue: runner)
        // One shared driver across families — it keeps a single warm model,
        // so cross-family switches evict before loading (see coordinator gate).
        ideogram4Runner.driver = driver
        krea2Runner.driver = driver
        zimageRunner.driver = driver
        // Remote access: shared generation services + embedded HTTP server.
        let bus = RemoteAccessEventBus()
        let service = GenerationService(
            settings: settings,
            fluxStore: store,
            fluxRunner: runner,
            krea2Store: krea2Store,
            krea2Runner: krea2Runner,
            zimageStore: zimageStore,
            zimageRunner: zimageRunner,
            coordinator: coordinator,
            timing: timing,
            gallery: gallery,
            bus: bus
        )
        service.ideogramStore = ideogram4Store
        _remoteEventBus = State(initialValue: bus)
        _generationService = State(initialValue: service)
        _remoteAccess = State(initialValue: RemoteAccessStore(
            settings: settings,
            service: service,
            bus: bus
        ))
        // Fold any pre-library default-LoRA list into LibraryLora.isDefault flags.
        loraLibrary.migrateLegacyDefaults(from: settings)
    }
}

/// Replaces the standard "About" menu item so it opens our custom About window,
/// which shows the running version and checks GitHub for the latest release.
struct AboutCommands: Commands {
    static let windowID = "about"

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About MLXBits Image Studio") {
                openWindow(id: Self.windowID)
            }
        }
    }
}

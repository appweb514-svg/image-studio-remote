import Foundation
import Testing

@testable import MLXBits_Image_Studio

@MainActor
@Suite("SuperscaleService recommendations")
struct SuperscaleRecommendationsTests {
    private func makeService() -> SuperscaleService {
        SuperscaleService(settings: AppSettings(), bus: RemoteAccessEventBus())
    }

    @Test("Native scale is recommended when it stays under 4K")
    func nativeRecommended() {
        let service = makeService()
        let recs = service.recommendations(sourceWidth: 512, sourceHeight: 512, modelName: "realesrgan-x4plus")
        #expect(!recs.isEmpty)
        // Native ×4: 2048×2048.
        #expect(recs.contains { $0.label == "Natif ×4" && $0.width == 2048 && $0.height == 2048 })
        #expect(recs.contains { $0.label == "×2" && $0.width == 1024 && $0.height == 1024 })
        // Exactly one recommendation is flagged.
        #expect(recs.filter(\.recommended).count == 1)
        #expect(recs.first(where: \.recommended)?.label == "Natif ×4")
    }

    @Test("Fit targets appear when they upscale and stay multiple of 8")
    func fitTargets() {
        let service = makeService()
        let recs = service.recommendations(sourceWidth: 1000, sourceHeight: 500, modelName: "realesrgan-x4plus")
        // 1000×500: 2K fit factor = min(2560/1000, 1440/500) = 2.56 → 2560×1280.
        #expect(recs.contains { $0.label == "Fit 2K" && $0.width == 2560 && $0.height == 1280 })
        for rec in recs {
            #expect(rec.width % 8 == 0)
            #expect(rec.height % 8 == 0)
        }
    }

    @Test("Huge native output degrades to a fit-4K recommendation")
    func fourKDegradation() {
        let service = makeService()
        // 1200×1200 ×4 = 4800 > 4096 → native not recommended, Fit 4K is.
        let recs = service.recommendations(sourceWidth: 1200, sourceHeight: 1200, modelName: "realesrgan-x4plus")
        #expect(!recs.first(where: \.recommended)!.label.contains("Natif"))
        #expect(recs.contains { $0.label == "Fit 4K" && $0.recommended })
    }

    @Test("Unknown model returns no recommendations")
    func unknownModel() {
        let service = makeService()
        #expect(service.recommendations(sourceWidth: 512, sourceHeight: 512, modelName: "nope").isEmpty)
    }
}

import Foundation

/// Machine facts for the remote Dashboard. Only metrics that macOS actually
/// reports — nothing invented.
struct SystemInfoSnapshot: Encodable {
    struct Versions: Encodable {
        let app: String
        let mflux: String?
        let macOS: String
    }

    struct Memory: Encodable {
        let totalGB: Double
        let pressureRatio: Double?
        let swapUsedGB: Double?
    }

    struct Storage: Encodable {
        let freeGB: Double
        let totalGB: Double
    }

    let chip: String
    let chipGeneration: String
    let memory: Memory
    let storage: Storage
    let loadedModel: String?
    let loadedModelMemoryGB: Double?
    let queueLength: Int
    let versions: Versions

    static func current(
        queueLength: Int,
        loadedModel: String?,
        loadedModelMemoryGB: Double?,
        mfluxVersion: String?
    ) -> SystemInfoSnapshot {
        let chip = chipName()
        return SystemInfoSnapshot(
            chip: chip,
            chipGeneration: chipGeneration(from: chip),
            memory: memoryInfo(),
            storage: storageInfo(),
            loadedModel: loadedModel,
            loadedModelMemoryGB: loadedModelMemoryGB,
            queueLength: queueLength,
            versions: Versions(
                app: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                mflux: mfluxVersion,
                macOS: ProcessInfo.processInfo.operatingSystemVersionString
            )
        )
    }

    private static func chipName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    private static func chipGeneration(from chip: String) -> String {
        // "Apple M1 Pro" → "M1", "Apple M4" → "M4"
        if let range = chip.range(of: "M\\d+[A-Za-z]*", options: .regularExpression) {
            return String(chip[range])
        }
        return chip
    }

    private static func memoryInfo() -> Memory {
        let total = ProcessInfo.processInfo.physicalMemory

        var pressure: Double?
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { statsPointer in
            statsPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPointer, &count)
            }
        }
        if result == KERN_SUCCESS {
            let pageSize: UInt64 = 16_384
            let used = UInt64(stats.active_count + stats.wire_count + stats.compressor_page_count) * pageSize
            pressure = min(1.0, Double(used) / Double(total))
        }

        var swapUsed: Double?
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            swapUsed = Double(swap.xsu_used) / 1_073_741_824.0
        }

        return Memory(
            totalGB: Double(total) / 1_073_741_824.0,
            pressureRatio: pressure,
            swapUsedGB: swapUsed
        )
    }

    private static func storageInfo() -> Storage {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return Storage(
            freeGB: Double(values?.volumeAvailableCapacityForImportantUsage ?? 0) / 1_073_741_824.0,
            totalGB: Double(values?.volumeTotalCapacity ?? 0) / 1_073_741_824.0
        )
    }
}

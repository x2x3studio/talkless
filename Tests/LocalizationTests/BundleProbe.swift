import Foundation

/// Compiled by SwiftPM alongside the unmodified product localization/validation
/// sources and SwiftPM's real generated resource accessor (not a test replacement).
@main
struct BundleProbe {
    static func main() {
        if CommandLine.arguments.contains("--verify-bundle") {
            // Dependency probes belong to the real executable's hermetic release
            // gate. This dependency-free fixture tests the exact package preflight.
            exit(BundleValidation.emit(BundleValidation.inspect()))
        }
        let catalog = LocalizationCatalog()
        let payload: [String: Any] = [
            "packaged": LocalizationCatalog.applicationURL(for: .main) != nil,
            "bundlePath": catalog.bundle?.bundleURL.resolvingSymlinksInPath().path ?? "",
            "english": catalog.string("Follow System", localization: "en"),
            "chinese": catalog.string("Follow System", localization: "zh-Hans"),
            "missingKey": catalog.string("Readable missing English key", localization: "zh-Hans"),
            "globalLookup": L10n.tr("Readable missing English key"),
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
    }
}

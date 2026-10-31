import Foundation
#if canImport(Hub)
import Hub
#endif

/// Read-only package checks. Do not use settings, diagnostics, model managers, or
/// localized error descriptions here: this runs before any application startup.
enum BundleValidation {
    struct Report: Encodable, Sendable {
        var status: String { errors.isEmpty ? "ok" : "failed" }
        var appPath: String
        var localizationBundlePath: String?
        var resourceBundlePaths: [String: String] = [:]
        var localizations: [String] = []
        var dependencyProbe = "not_run"
        var errors: [String] = []

        enum CodingKeys: String, CodingKey {
            case status, appPath, localizationBundlePath, resourceBundlePaths, localizations, dependencyProbe, errors
        }

        init(appPath: String) { self.appPath = appPath }

        // Include computed status in the machine-readable release gate contract.
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(status, forKey: .status)
            try values.encode(appPath, forKey: .appPath)
            try values.encodeIfPresent(localizationBundlePath, forKey: .localizationBundlePath)
            try values.encode(resourceBundlePaths, forKey: .resourceBundlePaths)
            try values.encode(localizations, forKey: .localizations)
            try values.encode(dependencyProbe, forKey: .dependencyProbe)
            try values.encode(errors, forKey: .errors)
        }
    }

    static let requiredResourceBundles: Set<String> = [
        LocalizationCatalog.resourceBundleName, "swift-transformers_Hub.bundle", "swift-crypto_Crypto.bundle",
    ]

    static func inspect(mainBundle: Bundle = .main) -> Report {
        var report = Report(appPath: mainBundle.bundleURL.resolvingSymlinksInPath().path)
        guard let appURL = LocalizationCatalog.applicationURL(for: mainBundle),
              let resources = mainBundle.resourceURL,
              LocalizationCatalog.isContained(resources, in: appURL) else {
            report.errors.append("not_packaged_app")
            return report
        }
        report.appPath = appURL.resolvingSymlinksInPath().path
        // Deliberately use the same resolver as L10n, with no development fallback.
        let bundle = LocalizationCatalog.resolveApplicationBundle(mainBundle: mainBundle) { nil }
        report.localizationBundlePath = bundle?.bundleURL.resolvingSymlinksInPath().path
        if let bundle {
            for language in ["en", "zh-Hans"] {
                guard let folder = bundle.url(forResource: language, withExtension: "lproj")
                        ?? bundle.url(forResource: language.lowercased(), withExtension: "lproj"),
                      LocalizationCatalog.isContained(folder, in: appURL),
                      let strings = stringTable(at: folder.appendingPathComponent("Localizable.strings"), inside: appURL),
                      !strings.isEmpty, strings.values.allSatisfy({ !$0.isEmpty }),
                      strings["Follow System"] == (language == "en" ? "Follow System" : "\u{8DDF}\u{968F}\u{7CFB}\u{7EDF}"),
                      LocalizationCatalog(bundle: bundle).string("Follow System", localization: language) == strings["Follow System"] else {
                    report.errors.append("localization_missing_or_invalid:\(language)")
                    continue
                }
                report.localizations.append(language)
            }
        } else {
            report.errors.append("localization_bundle_missing")
        }
        for language in ["en", "zh-Hans"] {
            let folder = resources.appendingPathComponent("\(language).lproj")
            let table = stringTable(at: folder.appendingPathComponent("InfoPlist.strings"), inside: appURL)
            for key in ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"] {
                if table?[key]?.isEmpty != false { report.errors.append("permission_localization_missing:\(language):\(key)") }
            }
        }
        let manifestURL = resources.appendingPathComponent("SwiftPMResourceBundles.json")
        if LocalizationCatalog.isContained(manifestURL, in: appURL),
           let data = try? Data(contentsOf: manifestURL),
           let names = try? JSONDecoder().decode([String].self, from: data),
           Set(names).count == names.count,
           requiredResourceBundles.isSubset(of: Set(names)),
           names.allSatisfy({ !$0.contains("/") && !$0.contains("\\") && $0.hasSuffix(".bundle") && !$0.hasPrefix(".") }) {
            for name in names.sorted() {
                let url = resources.appendingPathComponent(name)
                guard LocalizationCatalog.isContained(url, in: appURL), let resourceBundle = Bundle(url: url) else {
                    report.errors.append("resource_bundle_missing:\(name)")
                    continue
                }
                guard descendantsAreContained(in: url, appURL: appURL) else {
                    report.errors.append("resource_bundle_external_or_unreadable:\(name)")
                    continue
                }
                report.resourceBundlePaths[name] = resourceBundle.bundleURL.resolvingSymlinksInPath().path
                if name == "swift-transformers_Hub.bundle" {
                    // Hub prints parse failures to stdout. Preflight its probe file
                    // so even a damaged artifact emits exactly one JSON report.
                    guard let configURL = resourceBundle.url(forResource: "gpt2_tokenizer_config", withExtension: "json"),
                          LocalizationCatalog.isContained(configURL, in: appURL),
                          let data = try? Data(contentsOf: configURL),
                          let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          config["tokenizer_class"] as? String == "GPT2Tokenizer" else {
                        report.errors.append("hub_probe_resource_missing_or_invalid")
                        continue
                    }
                }
            }
        } else {
            report.errors.append("resource_bundle_manifest_missing_or_invalid")
        }
        for (relativePath, error) in [
            ("Contents/MacOS/mlx.metallib", "metal_library_missing"),
            ("Contents/Resources/AppIcon.icns", "app_icon_missing"),
            ("Contents/Frameworks/Sparkle.framework/Sparkle", "sparkle_framework_missing"),
        ] {
            let url = appURL.appendingPathComponent(relativePath)
            if !LocalizationCatalog.isContained(url, in: appURL)
                || !FileManager.default.isReadableFile(atPath: url.path) {
                report.errors.append(error)
            }
        }
        return report
    }

    /// Validate the full resource tree before invoking dependency accessors. A safe
    /// outer bundle path alone cannot prevent an inner JSON file escaping the app.
    private static func descendantsAreContained(in directory: URL, appURL: URL) -> Bool {
        var pending = [directory]
        var visited: Set<String> = []
        while let next = pending.popLast() {
            guard LocalizationCatalog.isContained(next, in: appURL) else { return false }
            let resolved = next.resolvingSymlinksInPath().standardizedFileURL
            guard visited.insert(resolved.path).inserted else { continue }
            guard let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey]),
                  values.isReadable == true else { return false }
            if values.isDirectory == true {
                guard let children = try? FileManager.default.contentsOfDirectory(at: resolved, includingPropertiesForKeys: nil) else { return false }
                pending.append(contentsOf: children)
            }
        }
        return true
    }

    private static func stringTable(at url: URL, inside appURL: URL) -> [String: String]? {
        guard LocalizationCatalog.isContained(url, in: appURL), let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: String]
    }

    static func run() async -> Int32 {
        var report = inspect()
        if report.errors.isEmpty {
            #if canImport(Hub)
            do {
                try await probeHubResources()
                report.dependencyProbe = "ok"
            } catch {
                // Do not print underlying errors: they may contain machine-specific data.
                report.dependencyProbe = "failed"
                report.errors.append("hub_resource_probe_failed")
            }
            #else
            report.errors.append("hub_resource_probe_unavailable")
            #endif
        }
        return emit(report)
    }

    @discardableResult
    static func emit(_ report: Report) -> Int32 {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(report) else { return 1 }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
        return report.errors.isEmpty ? 0 : 1
    }

    #if canImport(Hub)
    /// This public local-folder API reads Hub's actual generated Bundle.module
    /// fallback configuration. It cannot download a model or read user credentials.
    private static func probeHubResources() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TalklessBundleProbe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"model_type":"gpt2"}"#.utf8).write(to: directory.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
        let api = HubApi(downloadBase: directory, cache: nil, hfToken: "", endpoint: "https://invalid.invalid", useBackgroundSession: false)
        let loader = LanguageModelConfigurationFromHub(modelFolder: directory, hubApi: api)
        guard try await loader.tokenizerConfig?.tokenizerClass.string() == "GPT2Tokenizer" else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
    #endif
}

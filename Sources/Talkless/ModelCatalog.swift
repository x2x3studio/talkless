import Foundation

/// Only MLX checkpoints supported by the native runtime belong in this catalogue.
/// SpeakMore's similarly named Q8 GGUF checkpoint is a different format and is not interchangeable.
struct ModelFile: Codable, Equatable, Sendable {
    let name: String
    let bytes: Int64
    let sha256: String
}

struct ModelManifest: Codable, Equatable, Sendable {
    let modelID: String
    let repository: String
    let revision: String
    let files: [ModelFile]

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    func validate() throws {
        guard Self.isSafeComponent(modelID),
              repository.split(separator: "/", omittingEmptySubsequences: false).count == 2,
              repository.split(separator: "/").allSatisfy({ Self.isSafeComponent(String($0)) }),
              revision.count == 40, revision.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              !files.isEmpty, Set(files.map(\.name)).count == files.count else {
            throw ModelManagementError.invalidManifest
        }
        var total: Int64 = 0
        for file in files {
            guard Self.isSafeComponent(file.name), !file.name.hasPrefix("."),
                  !["model-manifest.json", "download-source.json"].contains(file.name),
                  file.bytes > 0, file.sha256.count == 64,
                  file.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw ModelManagementError.invalidManifest
            }
            let sum = total.addingReportingOverflow(file.bytes)
            guard !sum.overflow else { throw ModelManagementError.invalidManifest }
            total = sum.partialValue
        }
    }

    static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.utf8.count <= 200 &&
        value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }
}

struct CatalogModel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let summary: String
    let isRecommended: Bool
    let manifest: ModelManifest
    var totalBytes: Int64 { manifest.totalBytes }
}

enum ModelDownloadSource: Codable, Equatable, Sendable {
    case huggingFace
    case hfMirror
    /// A Hugging Face-compatible base URL, not a model folder or arbitrary file URL.
    case custom(URL)

    var title: String {
        switch self {
        case .huggingFace: "Hugging Face"
        case .hfMirror: "HF Mirror"
        case .custom: "Custom Mirror"
        }
    }

    var baseURL: URL {
        switch self {
        case .huggingFace: URL(string: "https://huggingface.co")!
        case .hfMirror: URL(string: "https://hf-mirror.com")!
        case .custom(let url): url
        }
    }

    func url(for file: ModelFile, manifest: ModelManifest) throws -> URL {
        try manifest.validate()
        guard manifest.files.contains(file), Self.isSecureURL(baseURL),
              baseURL.query == nil, baseURL.fragment == nil,
              !baseURL.path.contains(".."), !baseURL.path.contains("\\") else {
            throw ModelManagementError.invalidSource
        }
        return baseURL.appendingPathComponent(manifest.repository)
            .appendingPathComponent("resolve").appendingPathComponent(manifest.revision)
            .appendingPathComponent(file.name)
    }

    static func isSecureURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false &&
        url.user == nil && url.password == nil
    }
}

enum ModelManagementError: LocalizedError, Sendable {
    case invalidManifest, invalidSource, unknownModel, busy, notInstalled
    case unsafePath, unmanagedDirectory, corruptFile(String), download(String), coordinationRequired

    var errorDescription: String? {
        switch self {
        case .invalidManifest: "The model manifest is invalid."
        case .invalidSource: "Use an HTTPS mirror URL without credentials, a query, or a fragment."
        case .unknownModel: "This model is not in the managed catalogue."
        case .busy: "Wait for the current model operation to finish, or cancel its download."
        case .notInstalled: "Download and verify this model before using it."
        case .unsafePath: "The model folder contains an unsafe path or symbolic link. No files were removed."
        case .unmanagedDirectory: "This folder is not a verified Talkless-managed model. Move it yourself before downloading here."
        case .corruptFile(let name): "Verification failed for \(name). Retry to download a clean copy."
        case .download(let message): "Model download failed: \(message)"
        case .coordinationRequired: "Stop dictation and unload the active model before changing it."
        }
    }
}

enum ModelCatalog {
    static let defaultModelID = "Qwen3-ASR-0.6B-4bit"
    static let sources: [ModelDownloadSource] = [.huggingFace, .hfMirror]
    // hf-mirror.com returned the same pinned revision, file sizes, and LFS SHA-256 on
    // 2026-10-30. It can redirect to Hugging Face; it is not guaranteed to bypass network
    // restrictions. Every downloaded byte is still checked against this HF manifest.
    // No ModelScope entry: the reference app's Q8 GGUF mirror is not these MLX weights.
    static let mirrorNotice = "HF Mirror serves the same pinned files and may redirect to Hugging Face. Availability depends on your network."

    /// HF API /api/models/{repository}/revision/{revision}?blobs=true, checked 2026-10-30.
    /// Weight checksums are LFS SHA-256, not Git blob IDs. Small-file SHA-256 values
    /// were computed from the pinned resolve URLs.
    static let models: [CatalogModel] = [
        makeModel(
            id: defaultModelID, name: "Qwen3 ASR · 0.6B", recommended: true,
            summary: "Recommended · MLX 4-bit · Smaller download and memory footprint",
            revision: "313d850181767edf09f00a9c289becca70e58cd0",
            configBytes: 7187, configSHA: "923618cf5ca452fda0253a6be5c1a17f94a2e4851d3b98beb45848565587bd72",
            weightBytes: 708236945, weightSHA: "70c7e67e588062adce4f10796e47ad42ead51c6671eda61a0987eae38ca95ddf",
            indexBytes: 71814, indexSHA: "e3bb80ef0fd42a5be07b04e90c97d60460bbde8af3531e0bfe9100a61404d81a"
        ),
    ]

    static func model(id: String) -> CatalogModel? { models.first { $0.id == id } }

    private static func makeModel(
        id: String, name: String, recommended: Bool, summary: String, revision: String,
        configBytes: Int64, configSHA: String, weightBytes: Int64, weightSHA: String,
        indexBytes: Int64, indexSHA: String
    ) -> CatalogModel {
        let files = [
            ModelFile(name: "config.json", bytes: configBytes, sha256: configSHA),
            ModelFile(name: "tokenizer_config.json", bytes: 12487, sha256: "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"),
            ModelFile(name: "vocab.json", bytes: 2776833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
            ModelFile(name: "merges.txt", bytes: 1671853, sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
            ModelFile(name: "preprocessor_config.json", bytes: 330, sha256: "45e120a4eda2c20c5d7f2ea9354e63536bf35e27aa573fb7cdf78017b378770d"),
            ModelFile(name: "generation_config.json", bytes: 142, sha256: "1da527824d81e07118facff437e03f2e24a23311e3bdeb2368973fe77e5f275c"),
            ModelFile(name: "chat_template.json", bytes: 1161, sha256: "75a8cfca24f00de72d796fbfed6858fc9614ef3dabd8696684cc3bc03a9c58ff"),
            ModelFile(name: "model.safetensors.index.json", bytes: indexBytes, sha256: indexSHA),
            ModelFile(name: "model.safetensors", bytes: weightBytes, sha256: weightSHA),
        ]
        return CatalogModel(id: id, name: name, summary: summary, isRecommended: recommended,
                            manifest: ModelManifest(modelID: id, repository: "mlx-community/\(id)", revision: revision, files: files))
    }
}

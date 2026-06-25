import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers
import UIKit

/// Manages on-device LLM inference via Apple's MLX framework.
/// Handles model downloading, loading, generation, and lifecycle.
@MainActor
final class LocalLLMService: ObservableObject {
    @Published var isModelLoaded = false
    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false
    @Published var isGenerating = false
    @Published var isLoadingModel = false   // a model is being loaded into memory right now
    @Published var loadedModelId: String?
    @Published var downloadingModelId: String?
    @Published var lastLoadError: String?

    private var modelContainer: ModelContainer?
    private var activeDownloadTask: Task<Void, Error>?
    private var activeLoadTask: Task<Void, Never>?
    private var lifecycleObservers: [NSObjectProtocol] = []

    /// Set when the app enters the background during a generation so the token loop
    /// can stop before submitting the next Metal command buffer (forbidden in the
    /// background — see `generate`).
    private var enteredBackgroundDuringGeneration = false

    /// HubClient configured to store models in Application Support (persistent, not purgeable).
    private let hub: HubClient = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelsDir = appSupport.appendingPathComponent("LocalModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        return HubClient(cache: HubCache(cacheDirectory: modelsDir))
    }()

    init() {
        registerLifecycleObservers()
    }

    // MARK: - Recommended Models

    static let recommendedModels: [RecommendedModel] = [
        // Gemma 4 — best on-device agent model
        RecommendedModel(
            id: "mlx-community/gemma-4-e2b-it-4bit",
            name: "Gemma 4 E2B (Agent)",
            estimatedSize: "3.6 GB",
            hasVision: true,
            hasToolCalling: true,
            notes: "Best on-device agent — vision, tool calling, 140+ languages",
            minimumRAMGB: 8
        ),
        // Vision models (can see photos from glasses)
        RecommendedModel(
            id: "mlx-community/SmolVLM2-2.2B-Instruct-mlx",
            name: "SmolVLM2 2.2B (Vision)",
            estimatedSize: "1.5 GB",
            hasVision: true,
            hasToolCalling: false,
            notes: "Best small vision model — sees photos + video",
            minimumRAMGB: 6
        ),
        RecommendedModel(
            id: "mlx-community/SmolVLM2-500M-Video-Instruct-mlx",
            name: "SmolVLM2 500M (Vision)",
            estimatedSize: "0.35 GB",
            hasVision: true,
            hasToolCalling: false,
            notes: "Tiny vision model — basic photo understanding",
            minimumRAMGB: 4
        ),
        // Text-only MLX models
        RecommendedModel(
            id: "mlx-community/Qwen2.5-3B-Instruct-4bit",
            name: "Qwen 2.5 3B",
            estimatedSize: "1.8 GB",
            hasVision: false,
            hasToolCalling: true,
            notes: "Strong reasoning and tool use",
            minimumRAMGB: 6
        ),
        RecommendedModel(
            id: "mlx-community/gemma-2-2b-it-4bit",
            name: "Gemma 2 2B",
            estimatedSize: "1.5 GB",
            hasVision: false,
            hasToolCalling: true,
            notes: "Good balance of size and quality",
            minimumRAMGB: 5
        ),
        RecommendedModel(
            id: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            name: "Qwen 2.5 0.5B",
            estimatedSize: "0.4 GB",
            hasVision: false,
            hasToolCalling: true,
            notes: "Ultra-light, basic capability",
            minimumRAMGB: 4
        ),
    ]

    /// Known vision model IDs that need VLM inference.
    static let visionModelIds: Set<String> = [
        "mlx-community/SmolVLM2-2.2B-Instruct-mlx",
        "mlx-community/SmolVLM2-500M-Video-Instruct-mlx",
        "mlx-community/gemma-4-e2b-it-4bit",
    ]

    /// Whether the currently loaded model supports vision.
    var isVisionModel: Bool {
        guard let id = loadedModelId else { return false }
        return Self.visionModelIds.contains(id)
    }

    // MARK: - Model Management

    /// Download a model from HuggingFace without loading into memory.
    /// Only one download runs at a time — call cancelDownload() first if needed.
    func downloadModel(_ modelId: String) async throws {
        guard !isDownloading else { return }
        isDownloading = true
        downloadingModelId = modelId
        downloadProgress = 0
        defer {
            isDownloading = false
            downloadingModelId = nil
            activeDownloadTask = nil
        }

        guard let repoID = Repo.ID(rawValue: modelId) else {
            throw LocalLLMError.generationFailed("Invalid model id: \(modelId)")
        }
        _ = try await hub.downloadSnapshot(of: repoID) { @MainActor progress in
            self.downloadProgress = progress.fractionCompleted
        }

        downloadProgress = 1.0
        print("✅ Local model downloaded: \(modelId)")
    }

    /// Cancel any in-progress download and reset state.
    func cancelDownload() {
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        isDownloading = false
        downloadingModelId = nil
        downloadProgress = 0
    }

    /// Cancel an in-flight GPU load. MLX cannot always be stopped mid-load, but we clear
    /// state so voice queries can route to the VPS without waiting on a stuck load bar.
    func cancelActiveLoad() {
        activeLoadTask?.cancel()
        activeLoadTask = nil
        if isLoadingModel {
            isLoadingModel = false
            unloadModel()
        }
    }

    /// Whether GPU load is allowed for the current phone AI strategy.
    static var isGPULoadAllowed: Bool {
        switch Config.phoneAIStrategy {
        case .hybridVPSLocal, .vpsOnly:
            return false
        case .hybridLocalCloud, .cloudOnly:
            return true
        }
    }

    /// Load an already-downloaded model into memory.
    /// Uses LLMModelFactory for text models, VLMModelFactory for vision models.
    func loadModel(_ modelId: String) async throws {
        if loadedModelId == modelId && isModelLoaded {
            return  // Already loaded — no GPU work needed, safe even in background
        }

        lastLoadError = nil

        guard Self.isGPULoadAllowed else {
            throw LocalLLMError.generationFailed(
                "No modo híbrido/VPS a voz usa \(Config.agentName) no servidor. Carregar modelo local está desativado para evitar travamentos."
            )
        }

        // Refuse models that exceed this device's RAM before touching the GPU.
        // iOS kills the process on OOM with no catchable Swift error.
        try Self.validateDeviceRAM(for: modelId)

        // Download weights to disk first — never silently download during GPU load
        // (that showed "Loading…" with no visible download progress).
        if !isModelDownloaded(modelId) {
            try await downloadModel(modelId)
        }

        // Loading materializes model weights on the GPU via Metal (same restriction
        // as generate()), which iOS forbids in the background. The model is unloaded
        // when the app backgrounds, so a backgrounded scheduled task would otherwise
        // try to reload here and crash. Refuse early with a catchable error so callers
        // can defer.
        guard UIApplication.shared.applicationState == .active else {
            throw LocalLLMError.backgrounded
        }

        cancelActiveLoad()
        isLoadingModel = true
        unloadModel()

        let hub = hub
        var loadError: Error?
        let loadTask = Task { @MainActor in
            defer {
                isLoadingModel = false
                activeLoadTask = nil
            }
            do {
                let config = ModelConfiguration(id: modelId)
                let factory: any ModelFactory = Self.visionModelIds.contains(modelId)
                    ? VLMModelFactory.shared
                    : LLMModelFactory.shared
                modelContainer = try await factory.loadContainer(
                    from: #hubDownloader(hub),
                    using: #huggingFaceTokenizerLoader(),
                    configuration: config
                ) { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        self.downloadProgress = fraction
                    }
                }
                loadedModelId = modelId
                isModelLoaded = true
                print("✅ Local model loaded: \(modelId) (vision: \(Self.visionModelIds.contains(modelId)))")
            } catch {
                if !Task.isCancelled {
                    loadError = error
                    unloadModel()
                }
            }
        }
        activeLoadTask = loadTask

        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await loadTask.value
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        if !finished {
            cancelActiveLoad()
            let message = "Carregamento expirou após 2 minutos. Tente um modelo menor."
            lastLoadError = message
            throw LocalLLMError.generationFailed(message)
        }

        if let loadError {
            let message = loadError.localizedDescription
            lastLoadError = message
            throw LocalLLMError.generationFailed(message)
        }
    }

    /// Whether this device has enough RAM to load the given model.
    func canLoadModel(_ modelId: String) -> Bool {
        (try? Self.validateDeviceRAM(for: modelId)) != nil
    }

    /// RAM requirement message for UI, if the model won't fit.
    func ramRequirementMessage(for modelId: String) -> String? {
        guard let required = Self.minimumRAMGB(for: modelId), required > 0 else { return nil }
        let device = Self.deviceRAMGB
        guard device < required else { return nil }
        return String(format: "Precisa de %.0f GB de RAM — seu iPhone tem %.1f GB. Escolha um modelo menor.",
                      required, device)
    }

    /// Unload model from memory.
    func unloadModel() {
        modelContainer = nil
        loadedModelId = nil
        isModelLoaded = false
        print("🔄 Local model unloaded")
    }

    // MARK: - Generation

    /// Generate a text response from the local model.
    func generate(
        userMessage: String,
        systemPrompt: String,
        history: [(role: String, content: String)] = []
    ) async throws -> String {
        // On-device inference runs on the GPU via Metal, which iOS forbids in the
        // background: submitting a command buffer there raises
        // kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted, which MLX
        // surfaces as an *uncatchable* C++ exception that terminates the process.
        // Refuse early with a catchable Swift error so callers can defer instead.
        guard UIApplication.shared.applicationState != .background else {
            throw LocalLLMError.backgrounded
        }
        guard let container = modelContainer else {
            throw LocalLLMError.modelNotLoaded
        }

        isGenerating = true
        defer { isGenerating = false }

        // Build messages for chat template
        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]
        for turn in history {
            messages.append(["role": turn.role, "content": turn.content])
        }
        messages.append(["role": "user", "content": userMessage])

        // Tokenize using chat template — some models don't support system role,
        // so fall back to prepending system prompt to the first user message.
        let tokenizer = await container.tokenizer
        let tokens: [Int]
        do {
            tokens = try tokenizer.applyChatTemplate(messages: messages)
        } catch {
            print("⚠️ Chat template failed with system role, retrying without: \(error.localizedDescription)")
            // Merge system prompt into first user message
            var fallbackMessages: [[String: String]] = []
            for turn in history {
                fallbackMessages.append(["role": turn.role, "content": turn.content])
            }
            let combinedUserMessage = systemPrompt + "\n\nUser: " + userMessage
            fallbackMessages.append(["role": "user", "content": combinedUserMessage])
            tokens = try tokenizer.applyChatTemplate(messages: fallbackMessages)
        }
        // Build a 2D (1, L) batch, not a 1D (L,) array. The Gemma 4 / 3n forward pass
        // indexes x.dim(2) and fatally crashes ("SmallVector out of range") on 1D input —
        // its prepare() path doesn't expand 1D internally (ml-explore/mlx-swift-lm#240).
        // Other models accept (1, L) fine, so this is safe across the board.
        let tokenIDs = MLXArray(tokens).expandedDimensions(axis: 0)
        // NSLog (not print) so it survives the fatal MLX crash in the unified log,
        // confirming the 2D fix is live and what shape reaches the model.
        NSLog("🔬 LocalLLM.generate model=%@ tokenIDs.shape=%@ count=%d", loadedModelId ?? "?", "\(tokenIDs.shape)", tokens.count)
        let input = LMInput(text: .init(tokens: tokenIDs))

        // Watch for backgrounding *during* generation. The pre-check above covers
        // the already-backgrounded case; this covers the app being sent to the
        // background mid-stream, where the next per-token Metal eval would crash.
        enteredBackgroundDuringGeneration = false
        let bgObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Delivered on the main thread; this type is @MainActor.
            MainActor.assumeIsolated { self?.enteredBackgroundDuringGeneration = true }
        }
        defer { NotificationCenter.default.removeObserver(bgObserver) }

        // Generate
        let parameters = GenerateParameters(maxTokens: 512, temperature: 0.7, topP: 0.9)
        let stream = try await container.generate(input: input, parameters: parameters)

        var output = ""
        // Drive the stream manually so we can bail out *before* requesting the next
        // token — i.e. before MLX submits the next Metal command buffer. Stopping
        // here avoids the uncatchable background-GPU crash; whatever tokens we have
        // so far are returned (or .backgrounded is thrown if nothing was produced).
        var iterator = stream.makeAsyncIterator()
        while true {
            if enteredBackgroundDuringGeneration || UIApplication.shared.applicationState == .background {
                if output.isEmpty { throw LocalLLMError.backgrounded }
                break
            }
            guard let generation = await iterator.next() else { break }
            switch generation {
            case .chunk(let text):
                output += text
            case .info:
                break  // Generation complete info
            case .toolCall:
                break  // Handled at a higher level via text parsing
            @unknown default:
                break
            }
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Storage Info

    /// Persistent model storage directory (Application Support, never purged by iOS).
    var modelDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("LocalModels", isDirectory: true)
    }

    /// Get the on-disk path for a model. swift-huggingface uses a Python-compatible
    /// cache layout: <cacheDir>/models--{org}--{name}/
    private func modelPath(_ modelId: String) -> URL {
        let repoName = modelId.replacingOccurrences(of: "/", with: "--")
        return modelDirectory.appendingPathComponent("models--\(repoName)", isDirectory: true)
    }

    /// Check if a model is downloaded.
    func isModelDownloaded(_ modelId: String) -> Bool {
        FileManager.default.fileExists(atPath: modelPath(modelId).path)
    }

    /// Get size of a downloaded model on disk.
    func modelSizeOnDisk(_ modelId: String) -> Int64 {
        directorySize(modelPath(modelId))
    }

    /// Delete a downloaded model.
    func deleteModel(_ modelId: String) throws {
        if loadedModelId == modelId {
            unloadModel()
        }
        let path = modelPath(modelId)
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
            print("🗑️ Deleted local model: \(modelId)")
        }
    }

    /// List all downloaded model IDs by scanning the cache directory.
    func downloadedModelIds() -> [String] {
        // swift-huggingface stores as: <cacheDir>/models--{org}--{modelName}
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: modelDirectory, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var ids: [String] = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix("models--") else { continue }
            // models--{org}--{modelName} → {org}/{modelName}
            let repo = String(name.dropFirst("models--".count))
            let id = repo.replacingOccurrences(of: "--", with: "/")
            ids.append(id)
        }
        return ids.sorted()
    }

    // MARK: - Helpers

    private func registerLifecycleObservers() {
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                NSLog("⚠️ Memory warning — unloading local MLX model")
                self.unloadModel()
            }
        )
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                if self.isLoadingModel {
                    NSLog("📴 App backgrounded — cancelling in-flight MLX load")
                    self.cancelActiveLoad()
                } else if self.isModelLoaded {
                    NSLog("📴 App backgrounded — unloading local MLX model (Metal forbidden in background)")
                    self.unloadModel()
                }
            }
        )
    }

    private static func minimumRAMGB(for modelId: String) -> Double? {
        recommendedModels.first(where: { $0.id == modelId })?.minimumRAMGB
    }

    private static func validateDeviceRAM(for modelId: String) throws {
        guard let required = minimumRAMGB(for: modelId), required > 0 else { return }
        let device = deviceRAMGB
        guard device >= required else {
            throw LocalLLMError.insufficientMemory(requiredGB: required, deviceGB: device)
        }
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

// MARK: - Types

enum LocalLLMError: LocalizedError {
    case modelNotLoaded
    case generationFailed(String)
    case backgrounded
    case insufficientMemory(requiredGB: Double, deviceGB: Double)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No local model is loaded. Download one in Settings → AI Models."
        case .generationFailed(let reason):
            return "Local model generation failed: \(reason)"
        case .backgrounded:
            return "On-device models can't run while the app is in the background. Switch to a cloud model for background tasks."
        case .insufficientMemory(let requiredGB, let deviceGB):
            return String(format: "This model needs %.0f GB RAM but your iPhone has %.1f GB. Choose a smaller model (e.g. Qwen 0.5B).",
                          requiredGB, deviceGB)
        }
    }
}

struct RecommendedModel: Identifiable {
    let id: String
    let name: String
    let estimatedSize: String
    let hasVision: Bool
    let hasToolCalling: Bool
    let notes: String
    /// Minimum device RAM (GB) required to load this model. 0 = no restriction.
    let minimumRAMGB: Double

    init(id: String, name: String, estimatedSize: String, hasVision: Bool,
         hasToolCalling: Bool, notes: String, minimumRAMGB: Double = 0) {
        self.id = id
        self.name = name
        self.estimatedSize = estimatedSize
        self.hasVision = hasVision
        self.hasToolCalling = hasToolCalling
        self.notes = notes
        self.minimumRAMGB = minimumRAMGB
    }

    /// Whether the current device has enough RAM to run this model.
    var isCompatibleWithDevice: Bool {
        guard minimumRAMGB > 0 else { return true }
        return LocalLLMService.deviceRAMGB >= minimumRAMGB
    }
}

extension LocalLLMService {
    /// Physical RAM of this device in GB.
    nonisolated static var deviceRAMGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }

    /// Heaviest on-device model this iPhone can run — used for defaults and upgrades.
    nonisolated static var preferredDefaultModelId: String {
        let sorted = recommendedModels
            .filter(\.isCompatibleWithDevice)
            .sorted { lhs, rhs in
                if lhs.minimumRAMGB != rhs.minimumRAMGB { return lhs.minimumRAMGB > rhs.minimumRAMGB }
                if lhs.hasVision != rhs.hasVision { return lhs.hasVision }
                return lhs.hasToolCalling && !rhs.hasToolCalling
            }
        return sorted.first?.id ?? "mlx-community/Qwen2.5-3B-Instruct-4bit"
    }

    nonisolated static func displayName(forModelId id: String) -> String {
        recommendedModels.first(where: { $0.id == id })?.name ?? "Local"
    }
}

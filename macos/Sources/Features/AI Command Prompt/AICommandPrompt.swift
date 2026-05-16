#if os(macOS)
import AppKit
import Foundation
import SwiftUI

enum AICommandPromptProvider: String, CaseIterable, Identifiable {
    case ollama
    case lmStudio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        }
    }
}

enum AICommandPromptError: LocalizedError, Equatable {
    case noModel
    case noCommand
    case multiLineCommand
    case invalidResponse
    case server(statusCode: Int)
    case timeout
    case surfaceUnavailable

    var errorDescription: String? {
        switch self {
        case .noModel: "No model selected."
        case .noCommand: "The model did not return a command."
        case .multiLineCommand: "The model returned more than one line."
        case .invalidResponse: "The model response was not recognized."
        case .server(let statusCode): "Local model server returned HTTP \(statusCode)."
        case .timeout: "Local model server did not respond before the timeout."
        case .surfaceUnavailable: "The terminal is no longer available."
        }
    }
}

protocol AICommandPromptClient {
    func models(for provider: AICommandPromptProvider) async throws -> [String]
    func command(
        for instruction: String,
        provider: AICommandPromptProvider,
        model: String,
        workingDirectory: String?
    ) async throws -> String
}

protocol AICommandPromptTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionAICommandPromptTransport: AICommandPromptTransport {
    var session: URLSession = .shared

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

struct LocalAICommandPromptClient: AICommandPromptClient {
    var transport: AICommandPromptTransport = URLSessionAICommandPromptTransport()

    private let ollamaModelsURL = URL(string: "http://localhost:11434/api/tags")!
    private let ollamaChatURL = URL(string: "http://localhost:11434/api/chat")!
    private let lmStudioModelsURL = URL(string: "http://localhost:1234/v1/models")!
    private let lmStudioChatURL = URL(string: "http://localhost:1234/v1/chat/completions")!

    func models(for provider: AICommandPromptProvider) async throws -> [String] {
        switch provider {
        case .ollama:
            var request = URLRequest(url: ollamaModelsURL)
            request.timeoutInterval = 5
            let response: OllamaModelsResponse = try await decode(request)
            return response.models.map(\.modelName).filter { !$0.isEmpty }

        case .lmStudio:
            var request = URLRequest(url: lmStudioModelsURL)
            request.timeoutInterval = 5
            let response: LMStudioModelsResponse = try await decode(request)
            return response.data.map(\.id).filter { !$0.isEmpty }
        }
    }

    func command(
        for instruction: String,
        provider: AICommandPromptProvider,
        model: String,
        workingDirectory: String?
    ) async throws -> String {
        let messages = Self.messages(for: instruction, workingDirectory: workingDirectory)

        switch provider {
        case .ollama:
            var request = URLRequest(url: ollamaChatURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(OllamaChatRequest(
                model: model,
                messages: messages,
                stream: false
            ))
            let response: OllamaChatResponse = try await decode(request)
            guard let content = response.message?.content else { throw AICommandPromptError.invalidResponse }
            return content

        case .lmStudio:
            var request = URLRequest(url: lmStudioChatURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(LMStudioChatRequest(
                model: model,
                messages: messages,
                temperature: 0,
                maxTokens: 200,
                stream: false
            ))
            let response: LMStudioChatResponse = try await decode(request)
            guard let content = response.choices.first?.message.content else { throw AICommandPromptError.invalidResponse }
            return content
        }
    }

    private func decode<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await withTimeout(request.timeoutInterval) {
            try await transport.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AICommandPromptError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AICommandPromptError.server(statusCode: http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func withTimeout<T>(
        _ timeout: TimeInterval,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                let nanoseconds = UInt64(timeout * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw AICommandPromptError.timeout
            }

            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CancellationError()
            }

            return result
        }
    }

    private static func messages(for instruction: String, workingDirectory: String?) -> [AICommandChatMessage] {
        [
            AICommandChatMessage(
                role: "system",
                content: """
                You convert natural-language requests into exactly one shell command for macOS.
                Return only the command. Do not use Markdown. Do not explain. Do not wrap the command in quotes. Do not add a trailing newline.
                The command will be inserted into a terminal but not executed automatically.
                """
            ),
            AICommandChatMessage(
                role: "user",
                content: """
                Working directory: \(workingDirectory?.isEmpty == false ? workingDirectory! : "unknown")
                Request: \(instruction)
                """
            ),
        ]
    }
}

struct AICommandChatMessage: Codable, Equatable {
    let role: String
    let content: String
}

struct OllamaModelsResponse: Decodable, Equatable {
    let models: [Model]

    struct Model: Decodable, Equatable {
        let name: String
        let model: String?

        var modelName: String { model ?? name }
    }
}

struct OllamaChatRequest: Codable, Equatable {
    let model: String
    let messages: [AICommandChatMessage]
    let stream: Bool
}

struct OllamaChatResponse: Decodable, Equatable {
    let message: AICommandChatMessage?
}

struct LMStudioModelsResponse: Decodable, Equatable {
    let data: [Model]

    struct Model: Decodable, Equatable {
        let id: String
    }
}

struct LMStudioChatRequest: Codable, Equatable {
    let model: String
    let messages: [AICommandChatMessage]
    let temperature: Double
    let maxTokens: Int
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case stream
    }
}

struct LMStudioChatResponse: Decodable, Equatable {
    let choices: [Choice]

    struct Choice: Decodable, Equatable {
        let message: AICommandChatMessage
    }
}

@MainActor
final class AICommandPromptViewModel: ObservableObject {
    @Published var provider: AICommandPromptProvider {
        didSet {
            guard provider != oldValue else { return }
            defaults.set(provider.rawValue, forKey: Self.providerDefaultsKey)
            selectedModel = defaults.string(forKey: Self.modelDefaultsKey(provider)) ?? ""
            refreshModels()
        }
    }

    @Published var instruction: String = ""
    @Published private(set) var models: [String] = []
    @Published var selectedModel: String {
        didSet {
            guard !selectedModel.isEmpty else { return }
            defaults.set(selectedModel, forKey: Self.modelDefaultsKey(provider))
        }
    }
    @Published private(set) var isLoadingModels = false
    @Published private(set) var isGenerating = false
    @Published var errorMessage: String?

    private let client: AICommandPromptClient
    private let defaults: UserDefaults
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0

    private static let providerDefaultsKey = "AICommandPrompt.Provider"

    init(
        client: AICommandPromptClient? = nil,
        defaults: UserDefaults = .ghostty
    ) {
        self.client = client ?? Self.defaultClient()
        self.defaults = defaults

        let savedProvider = defaults.string(forKey: Self.providerDefaultsKey)
            .flatMap(AICommandPromptProvider.init(rawValue:)) ?? .ollama
        self.provider = savedProvider
        self.selectedModel = defaults.string(forKey: Self.modelDefaultsKey(savedProvider)) ?? ""
    }

    func refreshModels() {
        loadTask?.cancel()
        loadGeneration += 1

        let generation = loadGeneration
        let provider = provider

        models = []
        errorMessage = nil
        isLoadingModels = true

        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.loadModels(for: provider, generation: generation)
        }
    }

    func cancelRequests() {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        isLoadingModels = false
    }

    func resetPrompt() {
        instruction = ""
        errorMessage = nil
    }

    var selectedModelIsAvailable: Bool {
        !selectedModel.isEmpty && models.contains(selectedModel)
    }

    var canGenerate: Bool {
        selectedModelIsAvailable && !isLoadingModels && !isGenerating
    }

    func generateAndInsert(into surfaceView: Ghostty.SurfaceView) async -> Bool {
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstruction.isEmpty else {
            errorMessage = "Enter a request."
            return false
        }
        guard !isLoadingModels else {
            errorMessage = "Loading local models."
            return false
        }
        guard !selectedModel.isEmpty else {
            errorMessage = AICommandPromptError.noModel.localizedDescription
            return false
        }
        guard selectedModelIsAvailable else {
            errorMessage = "Selected model is no longer available."
            return false
        }
        guard let surface = surfaceView.surfaceModel else {
            errorMessage = AICommandPromptError.surfaceUnavailable.localizedDescription
            return false
        }

        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        do {
            let raw = try await client.command(
                for: trimmedInstruction,
                provider: provider,
                model: selectedModel,
                workingDirectory: surfaceView.pwd
            )
            let command = try Self.sanitizedCommand(from: raw)
            surface.sendText(command)
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    nonisolated static func sanitizedCommand(from raw: String) throws -> String {
        var command = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if command.hasPrefix("```") {
            var lines = command.components(separatedBy: .newlines)
            if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") == true {
                lines.removeFirst()
            }
            if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") == true {
                lines.removeLast()
            }
            command = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if command.hasPrefix("`"), command.hasSuffix("`"), command.count > 1 {
            command.removeFirst()
            command.removeLast()
            command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !command.isEmpty else { throw AICommandPromptError.noCommand }
        guard command.rangeOfCharacter(from: .newlines) == nil else {
            throw AICommandPromptError.multiLineCommand
        }

        return command
    }

    private func loadModels(
        for provider: AICommandPromptProvider,
        generation: Int
    ) async {
        isLoadingModels = true
        errorMessage = nil
        defer {
            if generation == loadGeneration {
                isLoadingModels = false
            }
        }

        do {
            let loaded = try await client.models(for: provider)
            guard !Task.isCancelled, generation == loadGeneration else { return }

            models = loaded
            if loaded.contains(selectedModel) {
                return
            }

            let saved = defaults.string(forKey: Self.modelDefaultsKey(provider)) ?? ""
            selectedModel = if loaded.contains(saved) {
                saved
            } else {
                loaded.first ?? ""
            }

            if loaded.isEmpty {
                errorMessage = "No local models found."
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            models = []
            selectedModel = ""
            errorMessage = error.localizedDescription
        }
    }

    private static func modelDefaultsKey(_ provider: AICommandPromptProvider) -> String {
        "AICommandPrompt.Model.\(provider.rawValue)"
    }

    private static func defaultClient() -> AICommandPromptClient {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let response = env["GHOSTTY_AI_COMMAND_PROMPT_MOCK_RESPONSE"] {
            let models = env["GHOSTTY_AI_COMMAND_PROMPT_MOCK_MODELS"]?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty } ?? ["mock-model"]
            return EnvironmentAICommandPromptClient(models: models, response: response)
        }
        #endif

        return LocalAICommandPromptClient()
    }
}

#if DEBUG
private struct EnvironmentAICommandPromptClient: AICommandPromptClient {
    let models: [String]
    let response: String

    func models(for provider: AICommandPromptProvider) async throws -> [String] {
        models
    }

    func command(
        for instruction: String,
        provider: AICommandPromptProvider,
        model: String,
        workingDirectory: String?
    ) async throws -> String {
        response
    }
}
#endif

@MainActor
struct TerminalAICommandPromptView: View {
    let surfaceView: Ghostty.SurfaceView
    @Binding var isPresented: Bool
    @StateObject private var viewModel: AICommandPromptViewModel
    @FocusState private var promptFocused: Bool
    @State private var submitTask: Task<Void, Never>?

    init(
        surfaceView: Ghostty.SurfaceView,
        isPresented: Binding<Bool>
    ) {
        self.surfaceView = surfaceView
        self._isPresented = isPresented
        self._viewModel = StateObject(wrappedValue: AICommandPromptViewModel())
    }

    init(
        surfaceView: Ghostty.SurfaceView,
        isPresented: Binding<Bool>,
        viewModel: AICommandPromptViewModel
    ) {
        self.surfaceView = surfaceView
        self._isPresented = isPresented
        self._viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        ZStack {
            if isPresented {
                GeometryReader { geometry in
                    VStack {
                        Spacer().frame(height: geometry.size.height * 0.05)

                        AICommandPromptResponderChainInjector(responder: surfaceView)
                            .frame(width: 0, height: 0)

                        prompt
                            .frame(maxWidth: 560)
                            .zIndex(1)

                        Spacer()
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                }
            }
        }
        .onChange(of: isPresented) { newValue in
            if newValue {
                viewModel.refreshModels()
                DispatchQueue.main.async {
                    promptFocused = true
                }
            } else {
                submitTask?.cancel()
                submitTask = nil
                viewModel.cancelRequests()
                viewModel.resetPrompt()
                DispatchQueue.main.async {
                    surfaceView.window?.makeFirstResponder(surfaceView)
                }
            }
        }
        .onDisappear {
            submitTask?.cancel()
            submitTask = nil
            viewModel.cancelRequests()
        }
    }

    private var prompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Command instructions", text: $viewModel.instruction)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .accessibilityIdentifier("AICommandPromptInput")
                    .focused($promptFocused)
                    .onExitCommand { isPresented = false }
                    .onSubmit { submit() }

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Picker("Provider", selection: $viewModel.provider) {
                    ForEach(AICommandPromptProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .labelsHidden()
                .frame(width: 120)

                Picker("Model", selection: $viewModel.selectedModel) {
                    if viewModel.models.isEmpty {
                        if viewModel.selectedModel.isEmpty {
                            Text("No Models").tag("")
                        } else {
                            Text(viewModel.selectedModel).tag(viewModel.selectedModel)
                        }
                    } else {
                        if !viewModel.selectedModel.isEmpty,
                           !viewModel.selectedModelIsAvailable {
                            Text(viewModel.selectedModel).tag(viewModel.selectedModel)
                        }

                        ForEach(viewModel.models, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }
                .labelsHidden()
                .frame(minWidth: 180)
                .disabled(viewModel.models.isEmpty || viewModel.isLoadingModels)

                if viewModel.isLoadingModels || viewModel.isGenerating {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer(minLength: 0)

                Button {
                    submit()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSubmit ? .primary : .tertiary)
                .disabled(!canSubmit)
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .tertiaryLabelColor).opacity(0.65))
        )
        .shadow(radius: 28, x: 0, y: 12)
        .padding()
    }

    private var canSubmit: Bool {
        !viewModel.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            viewModel.canGenerate
    }

    private func submit() {
        guard canSubmit else { return }

        submitTask?.cancel()
        submitTask = Task { @MainActor in
            if await viewModel.generateAndInsert(into: surfaceView) {
                isPresented = false
            }
            submitTask = nil
        }
    }
}

private struct AICommandPromptResponderChainInjector: NSViewRepresentable {
    let responder: NSResponder

    func makeNSView(context: Context) -> NSView {
        let dummy = NSView()
        DispatchQueue.main.async {
            dummy.nextResponder = responder
        }
        return dummy
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif

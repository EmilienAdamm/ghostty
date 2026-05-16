#if os(macOS)
import Foundation
import Testing
@testable import Ghostty

struct AICommandPromptTests {
    @Test func decodesOllamaModelsAndCommand() async throws {
        let client = LocalAICommandPromptClient(transport: MockAITransport { request in
            switch request.url?.path {
            case "/api/tags":
                return try Self.response(
                    for: request,
                    body: #"{"models":[{"name":"llama3.2:latest"},{"name":"ignored","model":"qwen2.5-coder:7b"}]}"#
                )

            case "/api/chat":
                let body = try #require(request.httpBody)
                let decoded = try JSONDecoder().decode(OllamaChatRequest.self, from: body)
                #expect(decoded.model == "qwen2.5-coder:7b")
                #expect(decoded.stream == false)
                return try Self.response(
                    for: request,
                    body: #"{"message":{"role":"assistant","content":"openssl rand -hex 32"}}"#
                )

            default:
                Issue.record("unexpected URL \(request.url?.absoluteString ?? "")")
                return try Self.response(for: request, status: 404, body: "{}")
            }
        })

        let models = try await client.models(for: .ollama)
        #expect(models == ["llama3.2:latest", "qwen2.5-coder:7b"])

        let command = try await client.command(
            for: "generate a secret",
            provider: .ollama,
            model: "qwen2.5-coder:7b",
            workingDirectory: "/tmp"
        )
        #expect(command == "openssl rand -hex 32")
    }

    @Test func decodesLMStudioModelsAndCommand() async throws {
        let client = LocalAICommandPromptClient(transport: MockAITransport { request in
            switch request.url?.path {
            case "/v1/models":
                return try Self.response(
                    for: request,
                    body: #"{"data":[{"id":"local-model"},{"id":"qwen3-coder"}]}"#
                )

            case "/v1/chat/completions":
                let body = try #require(request.httpBody)
                let decoded = try JSONDecoder().decode(LMStudioChatRequest.self, from: body)
                #expect(decoded.model == "local-model")
                #expect(decoded.stream == false)
                return try Self.response(
                    for: request,
                    body: #"{"choices":[{"message":{"role":"assistant","content":"tar -czf archive.tgz ."}}]}"#
                )

            default:
                Issue.record("unexpected URL \(request.url?.absoluteString ?? "")")
                return try Self.response(for: request, status: 404, body: "{}")
            }
        })

        let models = try await client.models(for: .lmStudio)
        #expect(models == ["local-model", "qwen3-coder"])

        let command = try await client.command(
            for: "compress this folder",
            provider: .lmStudio,
            model: "local-model",
            workingDirectory: nil
        )
        #expect(command == "tar -czf archive.tgz .")
    }

    @Test func sanitizesGeneratedCommand() throws {
        #expect(try AICommandPromptViewModel.sanitizedCommand(from: "openssl rand -hex 32\n") == "openssl rand -hex 32")
        #expect(try AICommandPromptViewModel.sanitizedCommand(from: "```sh\nls -la\n```") == "ls -la")
        #expect(try AICommandPromptViewModel.sanitizedCommand(from: "`pwd`") == "pwd")
    }

    @Test func rejectsUnsafeGeneratedCommandShapes() throws {
        do {
            _ = try AICommandPromptViewModel.sanitizedCommand(from: " \n ")
            Issue.record("empty command should throw")
        } catch let error as AICommandPromptError {
            #expect(error == .noCommand)
        }

        do {
            _ = try AICommandPromptViewModel.sanitizedCommand(from: "echo one\necho two")
            Issue.record("multi-line command should throw")
        } catch let error as AICommandPromptError {
            #expect(error == .multiLineCommand)
        }
    }

    @MainActor
    @Test func persistsProviderAndSelectedModel() async throws {
        let suite = "AICommandPromptTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = AICommandPromptViewModel(
            client: FakeAICommandPromptClient(modelsByProvider: [.lmStudio: ["model-a", "model-b"]]),
            defaults: defaults
        )

        model.provider = .lmStudio
        model.selectedModel = "model-b"

        let restored = AICommandPromptViewModel(
            client: FakeAICommandPromptClient(),
            defaults: defaults
        )
        #expect(restored.provider == .lmStudio)
        #expect(restored.selectedModel == "model-b")
    }

    @MainActor
    @Test func savedModelIsUnavailableUntilModelRefreshLoadsIt() async throws {
        let suite = "AICommandPromptTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("qwen3.6:latest", forKey: "AICommandPrompt.Model.ollama")

        let model = AICommandPromptViewModel(
            client: FakeAICommandPromptClient(),
            defaults: defaults
        )

        #expect(model.selectedModel == "qwen3.6:latest")
        #expect(model.selectedModelIsAvailable == false)
        #expect(model.canGenerate == false)
    }

    private static func response(
        for request: URLRequest,
        status: Int = 200,
        body: String
    ) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        ))
        return (Data(body.utf8), response)
    }
}

private struct MockAITransport: AICommandPromptTransport {
    let handler: (URLRequest) throws -> (Data, URLResponse)

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try handler(request)
    }
}

private struct FakeAICommandPromptClient: AICommandPromptClient {
    var modelsByProvider: [AICommandPromptProvider: [String]] = [:]
    var generatedCommand: String = "echo test"

    func models(for provider: AICommandPromptProvider) async throws -> [String] {
        modelsByProvider[provider] ?? []
    }

    func command(
        for instruction: String,
        provider: AICommandPromptProvider,
        model: String,
        workingDirectory: String?
    ) async throws -> String {
        generatedCommand
    }
}
#endif

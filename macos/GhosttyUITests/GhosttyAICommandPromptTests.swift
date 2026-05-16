//
//  GhosttyAICommandPromptTests.swift
//  Ghostty
//

import XCTest

final class GhosttyAICommandPromptTests: GhosttyCustomConfigCase {
    @MainActor
    func testInsertsCommandWithoutExecutingInFocusedSplit() throws {
        try updateConfig("")

        let testRoot = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("ghostty-ai-command-\(UUID().uuidString)")
        let focusedDirectory = testRoot.appendingPathComponent("focused")
        let output = testRoot.appendingPathComponent("pwd.txt")
        try FileManager.default.createDirectory(at: focusedDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let app = try ghosttyApplication(defaultsSuite: "GHOSTTY_AI_COMMAND_PROMPT_UI_TESTS")
        app.launchEnvironment["GHOSTTY_AI_COMMAND_PROMPT_MOCK_MODELS"] = "mock-model"
        app.launchEnvironment["GHOSTTY_AI_COMMAND_PROMPT_MOCK_RESPONSE"] = "pwd > \(output.path)"
        app.launchEnvironment["GHOSTTY_CLEAR_USER_DEFAULTS"] = "YES"
        app.launch()

        let terminal = app.groups["Terminal pane"]
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "New window should appear")

        terminal.typeKey("d", modifierFlags: .command)
        app.typeText("cd \(focusedDirectory.path)\r")

        terminal.typeKey("k", modifierFlags: .command)

        let input = app.textFields["AICommandPromptInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5), "AI command prompt should appear")
        input.typeText("write current directory")
        input.typeKey(.enter, modifierFlags: [])

        XCTAssertTrue(input.waitForNonExistence(timeout: 5), "AI command prompt should disappear after inserting")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "Generated command should not execute before Return")

        app.typeKey(.enter, modifierFlags: [])
        XCTAssertTrue(waitForFile(at: output, timeout: 5), "Inserted command should execute after Return")

        let written = try String(contentsOf: output, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(written, focusedDirectory.path)
    }

    private func waitForFile(at url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }
}

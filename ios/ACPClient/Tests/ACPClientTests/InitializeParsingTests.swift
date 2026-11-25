import XCTest
import ACP
@testable import ACPClient

final class InitializeParsingTests: XCTestCase {
    // SC-AC-013: Valid ACP initialize response extracts agentInfo, modes, authMethods;
    // empty {}, Codex userAgent-only, and unrelated objects strictly return nil.
    func testSCAC013_ParseInitializeACPExtractsModesAndAuthMethods() {
        let result: ACP.Value = .object([
            "protocolVersion": .number(1),
            "agentInfo": .object([
                "name": .string("antigravity"),
                "version": .string("0.4.0"),
                "title": .string("Antigravity"),
            ]),
            "agentCapabilities": .object([
                "loadSession": .bool(true),
                "promptCapabilities": .object([
                    "image": .bool(true),
                    "audio": .bool(true),
                    "embeddedContext": .bool(true),
                ]),
            ]),
            "modes": .object([
                "currentModeId": .string("default"),
                "availableModes": .array([
                    .object(["id": .string("plan"), "name": .string("Plan"), "description": .string("Analyze only")]),
                    .object(["id": .string("default"), "name": .string("Default"), "description": .string("Require approval")]),
                ]),
            ]),
            "authMethods": .array([
                .object([
                    "id": .string("oauth-personal"),
                    "name": .string("Log in with Google"),
                    "description": .null,
                ]),
                .object([
                    "id": .string("gemini-api-key"),
                    "name": .string("Use Gemini API key"),
                    "description": .string("Requires setting the GEMINI_API_KEY environment variable"),
                ]),
            ]),
        ])

        let parsed = ACPInitializeParser.parse(result: result)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.agentInfo?.name, "antigravity")
        XCTAssertEqual(parsed?.agentInfo?.modes.count, 2)
        XCTAssertEqual(parsed?.currentModeId, "default")
        XCTAssertEqual(parsed?.authMethods.count, 2)
        XCTAssertTrue(parsed?.promptCapabilitiesDeclared ?? false)
    }

    // SC-AC-013: Non-ACP payloads strictly return nil.
    func testSCAC013_ParseInitializeRejectsEmptyCodexAndUnrelatedPayloads() {
        XCTAssertNil(ACPInitializeParser.parse(result: .object([:])))
        XCTAssertNil(ACPInitializeParser.parse(result: .object(["userAgent": .string("codex/1.0.0")])))
        XCTAssertNil(ACPInitializeParser.parse(result: .object(["hello": .string("world")])))
        XCTAssertNil(ACPInitializeParser.parse(result: nil))
    }

    func testParseInitializeAcceptsWhenACPMarkersExist() {
        let result: ACP.Value = .object([
            "protocolVersion": .number(1),
            "agentInfo": .object([
                "name": .string("test-agent"),
            ]),
        ])

        let parsed = ACPInitializeParser.parse(result: result)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.agentInfo?.name, "test-agent")
    }
}

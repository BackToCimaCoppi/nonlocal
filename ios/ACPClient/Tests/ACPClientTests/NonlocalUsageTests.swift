import ACP
import Foundation
import XCTest
@testable import ACPClient
import ACPClientMocks

final class NonlocalUsageTests: XCTestCase {

    // AC-101: nonlocal/usage & nonlocal/usage_updated decode cold-start null fields,
    // missing optional resetTime/description, complete model pools without /credits,
    // and ACPResponseDispatcher.dispatchSuccess short-circuits both methods.
    func testAC101ColdStartAndFullUsageDecodingAndDispatcherShortCircuit() async throws {
        let coldStartPayload: ACP.Value = .object([
            "fetchedAt": .null,
            "ageSeconds": .null,
            "ttlSeconds": .int(180),
            "refreshing": .bool(true),
            "groups": .array([]),
            "lastError": .object([
                "code": .string("auth_required"),
                "message": .string("Authentication required"),
                "failedAt": .string("2026-11-19T12:00:00Z")
            ])
        ])

        let coldParsed = try XCTUnwrap(NonlocalUsageParser.parse(from: coldStartPayload))
        XCTAssertNil(coldParsed.fetchedAt)
        XCTAssertNil(coldParsed.ageSeconds)
        XCTAssertEqual(coldParsed.ttlSeconds, 180)
        XCTAssertTrue(coldParsed.refreshing)
        XCTAssertNil(coldParsed.tier)
        XCTAssertTrue(coldParsed.groups.isEmpty)
        XCTAssertEqual(
            coldParsed.lastError,
            NonlocalUsageError(
                code: "auth_required",
                message: "Authentication required",
                failedAt: "2026-11-19T12:00:00Z"
            )
        )

        let fullPayload: ACP.Value = .object([
            "fetchedAt": .string("2026-11-19T12:03:00Z"),
            "ageSeconds": .int(12),
            "ttlSeconds": .int(180),
            "refreshing": .bool(false),
            "tier": .object([
                "name": .string("Google AI Pro"),
                "id": .string("g1-pro-tier")
            ]),
            "groups": .array([
                .object([
                    "name": .string("Gemini 4"),
                    "buckets": .array([
                        .object([
                            "id": .string("g4-5h"),
                            "name": .string("5h Window"),
                            "window": .string("5h"),
                            "remainingFraction": .double(0.75)
                        ]),
                        .object([
                            "id": .string("g4-weekly"),
                            "name": .string("Weekly Window"),
                            "window": .string("weekly"),
                            "remainingFraction": .int(1),
                            "resetTime": .string("2026-11-24T00:00:00Z")
                        ])
                    ])
                ])
            ])
        ])

        let fullParsed = try XCTUnwrap(NonlocalUsageParser.parse(from: fullPayload))
        XCTAssertEqual(fullParsed.fetchedAt, "2026-11-19T12:03:00Z")
        XCTAssertEqual(fullParsed.ageSeconds, 12)
        XCTAssertEqual(fullParsed.ttlSeconds, 180)
        XCTAssertFalse(fullParsed.refreshing)
        XCTAssertEqual(fullParsed.tier, NonlocalUsageTier(name: "Google AI Pro", id: "g1-pro-tier"))
        XCTAssertEqual(fullParsed.groups.count, 1)
        XCTAssertNil(fullParsed.groups[0].description)
        XCTAssertEqual(fullParsed.groups[0].buckets.count, 2)
        XCTAssertNil(fullParsed.groups[0].buckets[0].resetTime)
        XCTAssertEqual(fullParsed.groups[0].buckets[0].remainingFraction, 0.75, accuracy: 0.0001)
        XCTAssertEqual(fullParsed.groups[0].buckets[1].remainingFraction, 1.0, accuracy: 0.0001)
        XCTAssertEqual(fullParsed.groups[0].buckets[1].resetTime, "2026-11-24T00:00:00Z")
        XCTAssertNil(fullParsed.lastError)

        // Codable round-trip
        let encoded = try JSONEncoder().encode(fullParsed)
        let decoded = try JSONDecoder().decode(NonlocalUsageResult.self, from: encoded)
        XCTAssertEqual(decoded, fullParsed)

        // ResponseDispatcher must short-circuit both nonlocal/usage and nonlocal/usage_updated
        let pollutedResult: ACP.Value = .object([
            "sessionId": .string("should-not-activate"),
            "stopReason": .string("end_turn"),
            "fetchedAt": .null,
            "ageSeconds": .null,
            "ttlSeconds": .int(180),
            "refreshing": .bool(false),
            "groups": .array([])
        ])
        XCTAssertTrue(
            ACPResponseDispatcher.dispatchSuccess(
                result: pollutedResult,
                method: NonlocalMethods.usage,
                context: ACPResponseDispatchContext(pendingPlaceholderId: "ph-1")
            ).isEmpty
        )
        XCTAssertTrue(
            ACPResponseDispatcher.dispatchSuccess(
                result: pollutedResult,
                method: NonlocalMethods.usageUpdated,
                context: ACPResponseDispatchContext(pendingPlaceholderId: "ph-1")
            ).isEmpty
        )

        // End-to-end ACPService.fetchNonlocalUsage() wrapper
        let provider = MockWebSocketProvider()
        let client = ACPClient(
            configuration: .init(endpoint: URL(string: "ws://127.0.0.1:19999")!, pingInterval: nil),
            socketProvider: provider
        )
        let service = ACPService(client: client)
        try await service.connect()

        let _ = Task {
            let response = ACPWireMessage.response(.init(id: .int(1), result: fullPayload))
            let data = try JSONEncoder().encode(response)
            provider.connection.enqueue(.text(String(decoding: data, as: UTF8.self)))
        }

        let fetched = try await service.fetchNonlocalUsage()
        XCTAssertEqual(fetched, fullParsed)
        let sentText = try XCTUnwrap(provider.connection.sentTexts.first)
        let sentWire = try JSONDecoder().decode(ACPWireMessage.self, from: Data(sentText.utf8))
        guard case .request(let sentRequest) = sentWire else {
            return XCTFail("Expected outbound JSON-RPC request")
        }
        XCTAssertEqual(sentRequest.method, NonlocalMethods.usage)

        await service.disconnect()
    }
}

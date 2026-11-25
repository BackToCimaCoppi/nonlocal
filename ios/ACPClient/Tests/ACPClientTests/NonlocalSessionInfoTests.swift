import ACP
import Foundation
import XCTest
@testable import ACPClient
import ACPClientMocks

final class NonlocalSessionInfoTests: XCTestCase {

    // AC-201: nonlocal/session_info and nonlocal/session_deleted decode all fields
    // accurately and ACPResponseDispatcher.dispatchSuccess short-circuits both methods
    // so responses carrying sessionId never trigger .sessionActivated.
    func testAC201SessionInfoAndSessionDeletedDecodingAndDispatcherShortCircuit() async throws {
        let infoPayload: ACP.Value = .object([
            "sessionId": .string("sess-parent-1"),
            "displayTitle": .string("自定义标题"),
            "upstreamTitle": .string("Upstream Title"),
            "cwd": .string("/Users/demo/project"),
            "subagents": .array([
                .object([
                    "sessionId": .string("sess-sub-1"),
                    "upstreamTitle": .string("Codebase Researcher"),
                    "depth": .int(1)
                ]),
                .object([
                    "sessionId": .string("sess-sub-2"),
                    "upstreamTitle": .null,
                    "depth": .int(2)
                ])
            ])
        ])

        let parsedInfo = try XCTUnwrap(NonlocalSessionInfoParser.parseSessionInfo(from: infoPayload))
        XCTAssertEqual(parsedInfo.sessionId, "sess-parent-1")
        XCTAssertEqual(parsedInfo.displayTitle, "自定义标题")
        XCTAssertEqual(parsedInfo.upstreamTitle, "Upstream Title")
        XCTAssertEqual(parsedInfo.cwd, "/Users/demo/project")
        XCTAssertEqual(parsedInfo.subagents, [
            NonlocalSubagentInfo(sessionId: "sess-sub-1", upstreamTitle: "Codebase Researcher", depth: 1),
            NonlocalSubagentInfo(sessionId: "sess-sub-2", upstreamTitle: nil, depth: 2)
        ])

        // Codable round-trip
        let encodedInfo = try JSONEncoder().encode(parsedInfo)
        let decodedInfo = try JSONDecoder().decode(NonlocalSessionInfoResult.self, from: encodedInfo)
        XCTAssertEqual(decodedInfo, parsedInfo)

        let deletedPayload: ACP.Value = .object([
            "instanceId": .string("inst-001"),
            "sessionId": .string("sess-parent-1")
        ])
        let parsedDeleted = try XCTUnwrap(NonlocalSessionInfoParser.parseSessionDeleted(from: deletedPayload))
        XCTAssertEqual(parsedDeleted.instanceId, "inst-001")
        XCTAssertEqual(parsedDeleted.sessionId, "sess-parent-1")

        let deletedWithoutInstance: ACP.Value = .object([
            "sessionId": .string("sess-only-id")
        ])
        let parsedDeletedNoInstance = try XCTUnwrap(
            NonlocalSessionInfoParser.parseSessionDeleted(from: deletedWithoutInstance)
        )
        XCTAssertNil(parsedDeletedNoInstance.instanceId)
        XCTAssertEqual(parsedDeletedNoInstance.sessionId, "sess-only-id")

        // ResponseDispatcher must short-circuit both nonlocal/session_info and nonlocal/session_deleted
        let infoActions = ACPResponseDispatcher.dispatchSuccess(
            result: infoPayload,
            method: NonlocalMethods.sessionInfo,
            context: ACPResponseDispatchContext(pendingPlaceholderId: "ph-1")
        )
        XCTAssertTrue(infoActions.isEmpty, "nonlocal/session_info must NOT trigger .sessionActivated")

        let deletedActions = ACPResponseDispatcher.dispatchSuccess(
            result: deletedPayload,
            method: NonlocalMethods.sessionDeleted,
            context: ACPResponseDispatchContext(pendingPlaceholderId: "ph-1")
        )
        XCTAssertTrue(deletedActions.isEmpty, "nonlocal/session_deleted must NOT trigger .sessionActivated")

        // End-to-end ACPService.fetchSessionInfo(sessionId:) wrapper
        let provider = MockWebSocketProvider()
        let client = ACPClient(
            configuration: .init(endpoint: URL(string: "ws://127.0.0.1:19999")!, pingInterval: nil),
            socketProvider: provider
        )
        let service = ACPService(client: client)
        try await service.connect()

        let _ = Task {
            let response = ACPWireMessage.response(.init(id: .int(1), result: infoPayload))
            let data = try JSONEncoder().encode(response)
            provider.connection.enqueue(.text(String(decoding: data, as: UTF8.self)))
        }

        let fetched = try await service.fetchSessionInfo(sessionId: "sess-parent-1")
        XCTAssertEqual(fetched, parsedInfo)
        let sentText = try XCTUnwrap(provider.connection.sentTexts.first)
        let sentWire = try JSONDecoder().decode(ACPWireMessage.self, from: Data(sentText.utf8))
        guard case .request(let sentRequest) = sentWire else {
            return XCTFail("Expected outbound JSON-RPC request")
        }
        XCTAssertEqual(sentRequest.method, NonlocalMethods.sessionInfo)

        await service.disconnect()
    }
}

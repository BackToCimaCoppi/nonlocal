import ACP
import Foundation
import XCTest
@testable import ACPClient
import ACPClientMocks

final class NonlocalDeleteSessionTests: XCTestCase {

    // W2-AC-121: nonlocal/delete_session method constant, ResponseDispatcher top-level
    // short-circuit (0 .sessionActivated / 0 .stopReason), NonlocalDeleteErrorCode
    // (-32021..-32024) mapping, NonlocalDeleteSessionResult parsing, and end-to-end
    // ACPService.deleteSession(sessionId:) success & RPC error propagation (-32021..-32024, -32601).
    func testW2AC121DeleteSessionCodecDispatcherAndErrorCodePropagation() async throws {
        XCTAssertEqual(NonlocalMethods.deleteSession, "nonlocal/delete_session")

        // 1. ResponseDispatcher must short-circuit nonlocal/delete_session at the top,
        // even when result carries both sessionId and stopReason.
        let pollutedResult: ACP.Value = .object([
            "sessionId": .string("sess-del-1"),
            "deleted": .bool(true),
            "alreadyAbsent": .bool(false),
            "deletedSubagentIds": .array([.string("sub-1"), .string("sub-2")]),
            "deletedSubagentCount": .int(2),
            "warnings": .array([.string("annotations_cleanup_skipped")]),
            "stopReason": .string("end_turn")
        ])
        let dispatchedActions = ACPResponseDispatcher.dispatchSuccess(
            result: pollutedResult,
            method: NonlocalMethods.deleteSession,
            context: ACPResponseDispatchContext(pendingPlaceholderId: "ph-1")
        )
        XCTAssertTrue(
            dispatchedActions.isEmpty,
            "W2-AC-121: nonlocal/delete_session must short-circuit ResponseDispatcher and emit 0 actions"
        )

        // 2. NonlocalDeleteErrorCode exact mapping for -32021..-32024
        XCTAssertEqual(NonlocalDeleteErrorCode(rawValue: -32021), .sessionActive)
        XCTAssertEqual(NonlocalDeleteErrorCode(rawValue: -32022), .dbBusy)
        XCTAssertEqual(NonlocalDeleteErrorCode(rawValue: -32023), .deleteFailed)
        XCTAssertEqual(NonlocalDeleteErrorCode(rawValue: -32024), .storageUnconfigured)
        XCTAssertNil(NonlocalDeleteErrorCode(rawValue: -32601))
        XCTAssertNil(NonlocalDeleteErrorCode(rawValue: -32000))

        // 3. NonlocalDeleteSessionResult tolerant parsing & Codable round-trip
        let fullPayload: ACP.Value = .object([
            "sessionId": .string("sess-del-1"),
            "deleted": .bool(true),
            "alreadyAbsent": .bool(false),
            "deletedSubagentIds": .array([.string("sub-1"), .string("sub-2")]),
            "deletedSubagentCount": .int(2),
            "warnings": .array([.string("pb_missing")])
        ])
        let parsedFull = try XCTUnwrap(NonlocalDeleteSessionResult.parse(from: fullPayload))
        XCTAssertEqual(parsedFull.sessionId, "sess-del-1")
        XCTAssertTrue(parsedFull.deleted)
        XCTAssertFalse(parsedFull.alreadyAbsent)
        XCTAssertEqual(parsedFull.deletedSubagentIds, ["sub-1", "sub-2"])
        XCTAssertEqual(parsedFull.deletedSubagentCount, 2)
        XCTAssertEqual(parsedFull.warnings, ["pb_missing"])

        let encoded = try JSONEncoder().encode(parsedFull)
        let decoded = try JSONDecoder().decode(NonlocalDeleteSessionResult.self, from: encoded)
        XCTAssertEqual(decoded, parsedFull)

        // Partial/idempotent payload tolerance
        let partialPayload: ACP.Value = .object([
            "sessionId": .string("sess-already-gone"),
            "deleted": .bool(true),
            "alreadyAbsent": .bool(true)
        ])
        let parsedPartial = try XCTUnwrap(NonlocalDeleteSessionResult.parse(from: partialPayload))
        XCTAssertEqual(parsedPartial.sessionId, "sess-already-gone")
        XCTAssertTrue(parsedPartial.deleted)
        XCTAssertTrue(parsedPartial.alreadyAbsent)
        XCTAssertEqual(parsedPartial.deletedSubagentIds, [])
        XCTAssertEqual(parsedPartial.deletedSubagentCount, 0)
        XCTAssertEqual(parsedPartial.warnings, [])

        // Missing or empty sessionId returns nil
        XCTAssertNil(NonlocalDeleteSessionResult.parse(from: nil))
        XCTAssertNil(NonlocalDeleteSessionResult.parse(from: .object(["deleted": .bool(true)])))
        XCTAssertNil(NonlocalDeleteSessionResult.parse(from: .object(["sessionId": .string("")])))

        // 4. End-to-end ACPService.deleteSession(sessionId:) request/response & error codes
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

        let deleteResult = try await service.deleteSession(sessionId: "sess-del-1")
        XCTAssertEqual(deleteResult, parsedFull)

        let sentText = try XCTUnwrap(provider.connection.sentTexts.first)
        let sentWire = try JSONDecoder().decode(ACPWireMessage.self, from: Data(sentText.utf8))
        guard case .request(let sentRequest) = sentWire else {
            return XCTFail("Expected outbound JSON-RPC request")
        }
        XCTAssertEqual(sentRequest.method, NonlocalMethods.deleteSession)
        XCTAssertEqual(sentRequest.params.objectValue?["sessionId"]?.stringValue, "sess-del-1")

        // 5. Verify -32021, -32022, -32023, -32024, and -32601 all propagate via ACPServiceError.rpcCode
        let expectedErrors: [(code: Int, mapped: NonlocalDeleteErrorCode?)] = [
            (-32021, .sessionActive),
            (-32022, .dbBusy),
            (-32023, .deleteFailed),
            (-32024, .storageUnconfigured),
            (-32601, nil)
        ]

        for (index, item) in expectedErrors.enumerated() {
            let requestId = index + 2
            let _ = Task {
                let rawErrorJSON = #"{"jsonrpc":"2.0","id":\#(requestId),"error":{"code":\#(item.code),"message":"error \#(item.code)"}}"#
                provider.connection.enqueue(.text(rawErrorJSON))
            }
            do {
                _ = try await service.deleteSession(sessionId: "sess-err-\(item.code)")
                XCTFail("Expected RPC error \(item.code)")
            } catch let error as ACPServiceError {
                XCTAssertEqual(error.rpcCode, item.code)
                XCTAssertEqual(NonlocalDeleteErrorCode(serviceError: error), item.mapped)
            }
        }

        await service.disconnect()
    }
}

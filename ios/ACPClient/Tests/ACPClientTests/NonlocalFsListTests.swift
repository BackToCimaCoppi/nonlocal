import ACP
import Foundation
import XCTest
@testable import ACPClient
import ACPClientMocks

final class NonlocalFsListTests: XCTestCase {

    // AC-301: nonlocal/fs_list encodes all params, decodes parentPath: null,
    // truncated: true, symlink with targetType, short-circuits ResponseDispatcher,
    // and preserves reserved integer RPC error codes (-32011/-32012/-32013/-32602).
    func testAC301FsListCodecDispatcherAndReservedErrorCodes() async throws {
        let params = NonlocalFsListParams(
            path: "/",
            includeFiles: true,
            showHidden: false,
            query: "src",
            limit: 500
        )
        let encodedParams = params.acpValue().objectValue
        XCTAssertEqual(encodedParams?["path"]?.stringValue, "/")
        XCTAssertEqual(encodedParams?["includeFiles"]?.boolValue, true)
        XCTAssertEqual(encodedParams?["showHidden"]?.boolValue, false)
        XCTAssertEqual(encodedParams?["query"]?.stringValue, "src")
        XCTAssertEqual(encodedParams?["limit"]?.numberValue, 500)

        let listPayload: ACP.Value = .object([
            "path": .string("/"),
            "parentPath": .null,
            "homePath": .string("/Users/demo"),
            "totalCount": .int(520),
            "truncated": .bool(true),
            "entries": .array([
                .object([
                    "name": .string("Users"),
                    "path": .string("/Users"),
                    "type": .string("dir"),
                    "mtimeMs": .int(1763510400000)
                ]),
                .object([
                    "name": .string("current"),
                    "path": .string("/current"),
                    "type": .string("symlink"),
                    "targetType": .string("dir")
                ]),
                .object([
                    "name": .string("README.md"),
                    "path": .string("/README.md"),
                    "type": .string("file"),
                    "size": .int(2048),
                    "mtimeMs": .double(1763510400123)
                ]),
                .object([
                    "name": .string("dangling"),
                    "path": .string("/dangling"),
                    "type": .string("symlink"),
                    "targetType": .string("broken")
                ])
            ])
        ])

        let parsed = try XCTUnwrap(NonlocalFileSystemParser.parseFsList(from: listPayload))
        XCTAssertEqual(parsed.path, "/")
        XCTAssertNil(parsed.parentPath)
        XCTAssertEqual(parsed.homePath, "/Users/demo")
        XCTAssertEqual(parsed.totalCount, 520)
        XCTAssertTrue(parsed.truncated)
        XCTAssertEqual(parsed.entries.count, 4)
        XCTAssertEqual(parsed.entries[0].type, .dir)
        XCTAssertEqual(parsed.entries[0].mtimeMs, 1763510400000)
        XCTAssertEqual(parsed.entries[1].type, .symlink)
        XCTAssertEqual(parsed.entries[1].targetType, .dir)
        XCTAssertEqual(parsed.entries[2].type, .file)
        XCTAssertEqual(parsed.entries[2].size, 2048)
        XCTAssertEqual(parsed.entries[2].mtimeMs, 1763510400123)
        XCTAssertEqual(parsed.entries[3].targetType, .broken)

        // Codable round-trip
        let roundTripData = try JSONEncoder().encode(parsed)
        let roundTripDecoded = try JSONDecoder().decode(NonlocalFsListResult.self, from: roundTripData)
        XCTAssertEqual(roundTripDecoded, parsed)

        // ResponseDispatcher must short-circuit nonlocal/fs_list
        let pollutedResult: ACP.Value = .object([
            "sessionId": .string("should-not-activate"),
            "path": .string("/"),
            "homePath": .string("/Users/demo")
        ])
        XCTAssertTrue(
            ACPResponseDispatcher.dispatchSuccess(
                result: pollutedResult,
                method: NonlocalMethods.fsList,
                context: ACPResponseDispatchContext(pendingPlaceholderId: "ph-1")
            ).isEmpty
        )

        // End-to-end ACPService.listDirectory + integer RPC error codes (-32011/-32012/-32013/-32602)
        let provider = MockWebSocketProvider()
        let client = ACPClient(
            configuration: .init(endpoint: URL(string: "ws://127.0.0.1:19999")!, pingInterval: nil),
            socketProvider: provider
        )
        let service = ACPService(client: client)
        try await service.connect()

        let _ = Task {
            let response = ACPWireMessage.response(.init(id: .int(1), result: listPayload))
            let data = try JSONEncoder().encode(response)
            provider.connection.enqueue(.text(String(decoding: data, as: UTF8.self)))
        }
        let fetched = try await service.listDirectory(params)
        XCTAssertEqual(fetched, parsed)

        let errorCodes: [NonlocalFsErrorCode] = [
            .notFound,
            .notDirectory,
            .permissionDenied,
            .invalidParams
        ]
        for (index, expectedCode) in errorCodes.enumerated() {
            let requestId = index + 2
            let _ = Task {
                let rawErrorJSON = #"{"jsonrpc":"2.0","id":\#(requestId),"error":{"code":\#(expectedCode.rawValue),"message":"error \#(expectedCode.rawValue)"}}"#
                provider.connection.enqueue(.text(rawErrorJSON))
            }
            do {
                _ = try await service.listDirectory(NonlocalFsListParams(path: "/test"))
                XCTFail("Expected RPC error \(expectedCode.rawValue)")
            } catch let error as ACPServiceError {
                XCTAssertEqual(error.rpcCode, expectedCode.rawValue)
            }
        }

        await service.disconnect()
    }
}

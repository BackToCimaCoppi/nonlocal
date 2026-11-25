import ACP
import Foundation
import XCTest
@testable import ACPClient
import ACPClientMocks

final class NonlocalFsReadFileTests: XCTestCase {

    // AC-401: nonlocal/fs_read_file decodes text and image responses with all fields,
    // short-circuits ResponseDispatcher, and maps all 6 reserved integer error codes
    // (-32011/-32013/-32014/-32015/-32016/-32602) through ACPServiceError.rpcCode.
    func testAC401FsReadFileCodecDispatcherAndReservedErrorCodes() async throws {
        let textPayload: ACP.Value = .object([
            "path": .string("/Users/demo/README.md"),
            "name": .string("README.md"),
            "kind": .string("text"),
            "mimeType": .string("text/markdown"),
            "content": .string("# Hello Nonlocal\n"),
            "size": .int(600_000),
            "bytesRead": .int(524_288),
            "truncated": .bool(true),
            "mtimeMs": .int(1763510400000)
        ])

        let parsedText = try XCTUnwrap(NonlocalFileSystemParser.parseFsReadFile(from: textPayload))
        XCTAssertEqual(parsedText.path, "/Users/demo/README.md")
        XCTAssertEqual(parsedText.name, "README.md")
        XCTAssertEqual(parsedText.kind, .text)
        XCTAssertEqual(parsedText.mimeType, "text/markdown")
        XCTAssertEqual(parsedText.content, "# Hello Nonlocal\n")
        XCTAssertEqual(parsedText.size, 600_000)
        XCTAssertEqual(parsedText.bytesRead, 524_288)
        XCTAssertTrue(parsedText.truncated)
        XCTAssertEqual(parsedText.mtimeMs, 1763510400000)

        let imagePayload: ACP.Value = .object([
            "path": .string("/Users/demo/logo.png"),
            "name": .string("logo.png"),
            "kind": .string("image"),
            "mimeType": .string("image/png"),
            "content": .string("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="),
            "size": .int(68),
            "bytesRead": .int(68),
            "truncated": .bool(false)
        ])

        let parsedImage = try XCTUnwrap(NonlocalFileSystemParser.parseFsReadFile(from: imagePayload))
        XCTAssertEqual(parsedImage.kind, .image)
        XCTAssertEqual(parsedImage.mimeType, "image/png")
        XCTAssertEqual(parsedImage.size, 68)
        XCTAssertEqual(parsedImage.bytesRead, 68)
        XCTAssertFalse(parsedImage.truncated)
        XCTAssertNil(parsedImage.mtimeMs)

        // Codable round-trip
        let roundTripData = try JSONEncoder().encode(parsedText)
        let roundTripDecoded = try JSONDecoder().decode(NonlocalFsReadFileResult.self, from: roundTripData)
        XCTAssertEqual(roundTripDecoded, parsedText)

        // ResponseDispatcher must short-circuit nonlocal/fs_read_file
        let pollutedResult: ACP.Value = .object([
            "sessionId": .string("should-not-activate"),
            "path": .string("/Users/demo/README.md")
        ])
        XCTAssertTrue(
            ACPResponseDispatcher.dispatchSuccess(
                result: pollutedResult,
                method: NonlocalMethods.fsReadFile,
                context: ACPResponseDispatchContext(pendingPlaceholderId: "ph-1")
            ).isEmpty
        )

        // End-to-end ACPService.readFile(path:) + 6 reserved integer error codes
        let provider = MockWebSocketProvider()
        let client = ACPClient(
            configuration: .init(endpoint: URL(string: "ws://127.0.0.1:19999")!, pingInterval: nil),
            socketProvider: provider
        )
        let service = ACPService(client: client)
        try await service.connect()

        let _ = Task {
            let response = ACPWireMessage.response(.init(id: .int(1), result: textPayload))
            let data = try JSONEncoder().encode(response)
            provider.connection.enqueue(.text(String(decoding: data, as: UTF8.self)))
        }
        let fetchedText = try await service.readFile(path: "/Users/demo/README.md")
        XCTAssertEqual(fetchedText, parsedText)

        let errorCodes: [NonlocalFsErrorCode] = [
            .notFound,
            .permissionDenied,
            .isDirectory,
            .unsupportedBinary,
            .fileTooLarge,
            .invalidParams
        ]
        for (index, expectedCode) in errorCodes.enumerated() {
            let requestId = index + 2
            let _ = Task {
                let rawErrorJSON = #"{"jsonrpc":"2.0","id":\#(requestId),"error":{"code":\#(expectedCode.rawValue),"message":"error \#(expectedCode.rawValue)"}}"#
                provider.connection.enqueue(.text(rawErrorJSON))
            }
            do {
                _ = try await service.readFile(path: "/Users/demo/file")
                XCTFail("Expected RPC error \(expectedCode.rawValue)")
            } catch let error as ACPServiceError {
                XCTAssertEqual(error.rpcCode, expectedCode.rawValue)
            }
        }

        await service.disconnect()
    }
}

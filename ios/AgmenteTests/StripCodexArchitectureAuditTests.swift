import XCTest
import Foundation
import ACPClient
@testable import Agmente

/// Static architecture, dead-code removal, and boundary isolation audit tests
/// covering SC-AC-002 through SC-AC-010 (CASE-STATIC-01).
final class StripCodexArchitectureAuditTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AgmenteTests
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repo root
    }

    private var iosRoot: URL {
        repoRoot.appendingPathComponent("ios", isDirectory: true)
    }

    private func allFiles(
        under root: URL,
        extensions: Set<String>? = nil,
        excludingSubstrings: [String] = []
    ) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let path = url.path
            if excludingSubstrings.contains(where: { path.contains($0) }) { continue }
            if let extensions, !extensions.contains(url.pathExtension.lowercased()) { continue }
            urls.append(url)
        }
        return urls
    }

    private func scanFiles(
        _ files: [URL],
        forForbiddenLiterals literals: [String]
    ) -> [String] {
        var hits: [String] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let rel = file.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            for literal in literals {
                if text.contains(literal) {
                    hits.append("\(rel): contains '\(literal)'")
                }
            }
        }
        return hits
    }

    private func assertDoesNotExist(_ relativePath: String, ac: String) {
        let url = repoRoot.appendingPathComponent(relativePath)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "\(ac): Expected \(relativePath) to be deleted"
        )
    }

    private func assertExists(_ relativePath: String, ac: String) {
        let url = repoRoot.appendingPathComponent(relativePath)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "\(ac): Expected \(relativePath) to exist"
        )
    }

    // MARK: - SC-AC-002: Codex & AppServerClient complete removal

    func testSCAC002_CodexAndAppServerClientCompletelyRemoved() throws {
        assertDoesNotExist("ios/AppServerClient", ac: "SC-AC-002")
        assertDoesNotExist("ios/Agmente/CodexServerViewModel.swift", ac: "SC-AC-002")
        assertDoesNotExist("ios/Agmente/CodexSessionDetailView.swift", ac: "SC-AC-002")
        assertDoesNotExist("ios/Agmente/CodexSessionLogger.swift", ac: "SC-AC-002")
        assertDoesNotExist("ios/Agmente/CodexProtocolSummary.swift", ac: "SC-AC-002")
        assertDoesNotExist("ios/Agmente/PlanModeViews.swift", ac: "SC-AC-002")
        assertDoesNotExist("ios/Agmente/JSONRPCFormatter.swift", ac: "SC-AC-002")
        assertDoesNotExist("ios/AgmenteTests/CodexServerViewModelTests.swift", ac: "SC-AC-002")
        assertDoesNotExist("ios/AgmenteTests/CodexSessionDotsTests.swift", ac: "SC-AC-002")
        assertDoesNotExist("ios/AgmenteTests/CodexThreadReadMergeFixtureTests.swift", ac: "SC-AC-002")
        assertDoesNotExist("ios/AgmenteTests/Fixtures/CodexThreadReadMerge", ac: "SC-AC-002")

        let pbxproj = try String(contentsOf: iosRoot.appendingPathComponent("Agmente.xcodeproj/project.pbxproj"), encoding: .utf8)
        XCTAssertFalse(pbxproj.contains("AppServerClient"), "SC-AC-002: project.pbxproj must not reference AppServerClient")
        XCTAssertFalse(pbxproj.contains("(null) in Frameworks"), "SC-AC-002: project.pbxproj must have zero null frameworks")

        var sourceFiles = allFiles(
            under: iosRoot,
            extensions: ["swift"],
            excludingSubstrings: [
                ".build/",
                "StripCodexArchitectureAuditTests.swift",
                "Agmente.xcdatamodel/",
                "Agmente v2.xcdatamodel/"
            ]
        )
        let v3Contents = iosRoot.appendingPathComponent("Agmente/Agmente.xcdatamodeld/Agmente v3.xcdatamodel/contents")
        XCTAssertTrue(FileManager.default.fileExists(atPath: v3Contents.path), "SC-AC-002: Agmente v3.xcdatamodel/contents must exist")
        sourceFiles.append(v3Contents)
        let forbidden = [
            "CodexServerViewModel",
            "CodexSessionDetailView",
            "CodexSessionLogger",
            "CodexProtocolSummary",
            "PlanModeViews",
            "ServerType",
            "JSONRPCFormatter",
            "JSONRPCID",
            "onJSONRPCPermissionResponse",
            "onApproveRequest",
            "onDeclineRequest",
            "approvalRequestId",
            "approveButtonTitle",
            "declineButtonTitle",
            "pendingApprovalRequests",
            "activeUserInputRequest",
            "updateToolCallWithApproval",
            "clearApprovalForToolCall",
            "addUserInputRequest",
            "completePlanItem",
            "upsertToolCallFromAppServer",
        ]
        let hits = scanFiles(sourceFiles, forForbiddenLiterals: forbidden)
        XCTAssertTrue(hits.isEmpty, "SC-AC-002 forbidden symbols found:\n\(hits.joined(separator: "\n"))")
    }

    // MARK: - SC-AC-003: Cloudflare Access complete removal

    func testSCAC003_CloudflareAccessCompletelyRemoved() {
        let targets = [
            iosRoot.appendingPathComponent("Agmente"),
            iosRoot.appendingPathComponent("ACPClient"),
            iosRoot.appendingPathComponent("AgmenteTests"),
            iosRoot.appendingPathComponent("AgmenteUITests"),
        ]
        var files: [URL] = []
        for dir in targets {
            files += allFiles(
                under: dir,
                extensions: ["swift", "xcstrings", "plist", "xcdatamodel", "xml"],
                excludingSubstrings: [
                    ".build/",
                    "StripCodexArchitectureAuditTests.swift",
                    "Agmente.xcdatamodel/",
                    "Agmente v2.xcdatamodel/",
                    "CoreDataV3MigrationTests.swift", // tests v1/v2 migration of legacy cfAccess columns
                ]
            )
        }
        // Core Data .xcdatamodel is a directory whose XML payload is named "contents" (empty file extension).
        let v3Contents = iosRoot.appendingPathComponent("Agmente/Agmente.xcdatamodeld/Agmente v3.xcdatamodel/contents")
        XCTAssertTrue(FileManager.default.fileExists(atPath: v3Contents.path), "SC-AC-003: Agmente v3.xcdatamodel/contents must exist")
        files.append(v3Contents)
        let hits = scanFiles(files, forForbiddenLiterals: [
            "cfAccessClientId",
            "cfAccessClientSecret",
            "Cloudflare Access",
        ])
        XCTAssertTrue(hits.isEmpty, "SC-AC-003 CF Access residuals found:\n\(hits.joined(separator: "\n"))")
    }

    // MARK: - SC-AC-004: Third-party ACP & Gofer complete removal

    func testSCAC004_ThirdPartyACPAndGoferRemovedAndModelConstantInACPClient() {
        assertDoesNotExist("ios/Agmente/AgentCapabilitiesSummaryView.swift", ac: "SC-AC-004")
        assertDoesNotExist("ios/Agmente/ACPPlanChecklistView.swift", ac: "SC-AC-004")
        assertDoesNotExist("ios/Agmente/SessionSidebarView.swift", ac: "SC-AC-004")
        assertDoesNotExist("ios/ACPClient/Sources/ACPClient/ACP/GoferMethods.swift", ac: "SC-AC-004")
        assertDoesNotExist("ios/ACPClient/Sources/ACPClient/Models/GoferModel.swift", ac: "SC-AC-004")
        assertDoesNotExist("ios/ACPClient/Tests/ACPClientTests/GoferModelsParsingTests.swift", ac: "SC-AC-004")

        // Standard "model" configId constant resides in ACPClient under non-Gofer namespace
        XCTAssertEqual(ACPModelConfig.configId, "model", "SC-AC-004: ACPModelConfig.configId must equal 'model'")

        let swiftFiles = allFiles(
            under: iosRoot,
            extensions: ["swift"],
            excludingSubstrings: [
                ".build/",
                "StripCodexArchitectureAuditTests.swift",
                "LocalizationIntegrityTests.swift", // asserts Gofer is absent in UI strings
                "CoreDataV3MigrationTests.swift",   // cleans deprecated summaryCardCollapsed key
            ]
        )
        let hits = scanFiles(swiftFiles, forForbiddenLiterals: [
            "Gofer",
            "ACPPlanRowStyle",
            "AgentBehaviorRules",
            "canDeleteSessionsLocally",
            "applyDefaultModelFallbackIfNeeded",
        ])
        XCTAssertTrue(hits.isEmpty, "SC-AC-004 third-party/Gofer residuals:\n\(hits.joined(separator: "\n"))")

        // summaryCardCollapsed must NOT be used as live @AppStorage / state (allowed ONLY inside deprecated-key cleanup list for SC-AC-035)
        let summaryCardHits = scanFiles(
            swiftFiles.filter { !$0.lastPathComponent.hasPrefix("AppViewModel.swift") },
            forForbiddenLiterals: ["summaryCardCollapsed"]
        )
        XCTAssertTrue(summaryCardHits.isEmpty, "SC-AC-004 summaryCardCollapsed residuals:\n\(summaryCardHits.joined(separator: "\n"))")
        let appVMText = (try? String(contentsOf: iosRoot.appendingPathComponent("Agmente/AppViewModel.swift"), encoding: .utf8)) ?? ""
        XCTAssertFalse(appVMText.contains("@AppStorage(\"summaryCardCollapsed\")"), "SC-AC-004: live @AppStorage(summaryCardCollapsed) must be removed")
    }

    // MARK: - SC-AC-005: Pure iOS/iPadOS main app (macOS files, #if os(macOS), pbxproj keys removed)

    func testSCAC005_MacOSFilesConditionalCompilationAndPbxprojKeysRemoved() throws {
        assertDoesNotExist("ios/Agmente/NSColor+UISemantic.swift", ac: "SC-AC-005")
        assertDoesNotExist("ios/Agmente/SessionWindowStore.swift", ac: "SC-AC-005")
        assertDoesNotExist("ios/Agmente/PromptComposerCommands.swift", ac: "SC-AC-005")

        let appFiles = allFiles(
            under: iosRoot.appendingPathComponent("Agmente"),
            extensions: ["swift"]
        )
        let hits = scanFiles(appFiles, forForbiddenLiterals: [
            "#if os(macOS)",
            "canImport(AppKit)",
            "import AppKit",
            "targetEnvironment(macCatalyst)",
        ])
        XCTAssertTrue(hits.isEmpty, "SC-AC-005 macOS residuals in ios/Agmente/:\n\(hits.joined(separator: "\n"))")

        let pbxproj = try String(contentsOf: iosRoot.appendingPathComponent("Agmente.xcodeproj/project.pbxproj"), encoding: .utf8)
        XCTAssertTrue(pbxproj.contains("SUPPORTED_PLATFORMS = \"iphoneos iphonesimulator\";"), "SC-AC-005: SUPPORTED_PLATFORMS must be iphoneos iphonesimulator")
        for forbiddenKey in [
            "macosx",
            "MACOSX_DEPLOYMENT_TARGET",
            "SUPPORTS_MACCATALYST",
            "ENABLE_APP_SANDBOX",
            "ENABLE_HARDENED_RUNTIME",
        ] {
            XCTAssertFalse(pbxproj.contains(forbiddenKey), "SC-AC-005: project.pbxproj must not contain \(forbiddenKey)")
        }
    }

    // MARK: - SC-AC-006: External halliharp.com removal & MIT copyright intact

    func testSCAC006_ExternalSiteLinksRemovedAndMITLicensesIntact() throws {
        assertDoesNotExist("ios/SECURITY.md", ac: "SC-AC-006")
        assertDoesNotExist("ios/CODE_OF_CONDUCT.md", ac: "SC-AC-006")

        let allIOSFiles = allFiles(
            under: iosRoot,
            excludingSubstrings: [
                ".build/",
                "StripCodexArchitectureAuditTests.swift",
                "LocalizationIntegrityTests.swift", // asserts halliharp.com is absent from SettingsView
                ".png",
                ".jpg",
                ".pdf",
                ".xcassets/",
            ]
        )
        let hits = scanFiles(allIOSFiles, forForbiddenLiterals: ["halliharp.com"])
        XCTAssertTrue(hits.isEmpty, "SC-AC-006 halliharp.com residuals:\n\(hits.joined(separator: "\n"))")

        assertExists("LICENSE", ac: "SC-AC-006")
        assertExists("THIRD_PARTY_LICENSES.md", ac: "SC-AC-006")
        let license = try String(contentsOf: repoRoot.appendingPathComponent("LICENSE"), encoding: .utf8)
        let thirdParty = try String(contentsOf: repoRoot.appendingPathComponent("THIRD_PARTY_LICENSES.md"), encoding: .utf8)
        XCTAssertTrue(license.contains("MIT License"), "SC-AC-006: LICENSE must preserve MIT License")
        XCTAssertTrue(thirdParty.contains("MIT"), "SC-AC-006: THIRD_PARTY_LICENSES.md must preserve MIT attributions")
    }

    // MARK: - SC-AC-007: Test Transcript, old docs & old E2E dirs removed

    func testSCAC007_TestTranscriptOldDocsAndOldE2EDirsRemoved() {
        assertDoesNotExist("ios/Agmente/Debug/ChatComponentGalleryView.swift", ac: "SC-AC-007")
        assertDoesNotExist("ios/docs", ac: "SC-AC-007")
        assertDoesNotExist("ios/setup.md", ac: "SC-AC-007")
        assertDoesNotExist("ios/CONTRIBUTING.md", ac: "SC-AC-007")
        assertDoesNotExist("ios/e2e/backends", ac: "SC-AC-007")
        assertDoesNotExist("ios/e2e/scenarios", ac: "SC-AC-007")
        assertDoesNotExist("ios/e2e/schema", ac: "SC-AC-007")
        assertDoesNotExist("ios/e2e/assertions", ac: "SC-AC-007")

        assertDoesNotExist("ios/e2e", ac: "SC-AC-007")

        let swiftFiles = allFiles(
            under: iosRoot,
            extensions: ["swift"],
            excludingSubstrings: [".build/", "StripCodexArchitectureAuditTests.swift"]
        )
        let hits = scanFiles(swiftFiles, forForbiddenLiterals: [
            "ChatComponentGalleryView",
            "testTranscriptMenuAction",
            "devRowTranscriptButton",
            ".testTranscript",
        ])
        XCTAssertTrue(hits.isEmpty, "SC-AC-007 Test Transcript residuals:\n\(hits.joined(separator: "\n"))")
    }

    // MARK: - SC-AC-008: Single-track pool & zero polymorphic shells

    func testSCAC008_SingleTrackPoolAndZeroPolymorphicShells() throws {
        assertDoesNotExist("ios/Agmente/ServerViewModelProtocol.swift", ac: "SC-AC-008")
        assertDoesNotExist("ios/Agmente/ServerLifecycleController.swift", ac: "SC-AC-008")
        assertDoesNotExist("ios/Agmente/AgentInfo.swift", ac: "SC-AC-008")
        assertDoesNotExist("ios/ACPClient/Sources/ACPClient/Models/AgentDescriptor.swift", ac: "SC-AC-008")
        assertDoesNotExist("ios/Agmente/AppViewModel+Wave2.swift", ac: "SC-AC-008")

        assertExists("ios/Agmente/AppViewModel+DebugSeed.swift", ac: "SC-AC-008")
        let debugSeed = try String(contentsOf: iosRoot.appendingPathComponent("Agmente/AppViewModel+DebugSeed.swift"), encoding: .utf8)
        XCTAssertFalse(debugSeed.contains("serverType"), "SC-AC-008: DebugSeed must not contain serverType")
        XCTAssertFalse(debugSeed.contains("cfAccess"), "SC-AC-008: DebugSeed must not contain cfAccess")

        let appVMText = try String(contentsOf: iosRoot.appendingPathComponent("Agmente/AppViewModel.swift"), encoding: .utf8)
        XCTAssertFalse(appVMText.contains("ACPClientManagerDelegate"), "SC-AC-008: AppViewModel must no longer conform to ACPClientManagerDelegate")

        let swiftFiles = allFiles(
            under: iosRoot,
            extensions: ["swift"],
            excludingSubstrings: [".build/", "StripCodexArchitectureAuditTests.swift"]
        )
        let hits = scanFiles(swiftFiles, forForbiddenLiterals: [
            "legacyFallbackConnectionManager",
            "usesInjectedSingleConnectionManager",
            "sharedConnectionManagerClaimedBy",
            "connectInitializeAndFetchSessions",
            "updatesCache",
            "ServerViewModelProtocol",
            "selectedServerViewModelAny",
            "archiveSession",
            "as? ServerViewModel",
        ])
        XCTAssertTrue(hits.isEmpty, "SC-AC-008 dual-track/polymorphic residuals:\n\(hits.joined(separator: "\n"))")
    }

    // MARK: - SC-AC-009: Modular files exist with strict ownership & zero cyclic dependencies

    func testSCAC009_ModularFilesExistWithStrictOwnershipAndZeroCycle() throws {
        let requiredFiles = [
            "ios/Agmente/ServerConnectionPool.swift",
            "ios/Agmente/BridgeServerValidator.swift",
            "ios/Agmente/BridgeSyncCoordinator.swift",
            "ios/Agmente/QuotaManager.swift",
            "ios/Agmente/ChatMessageCache.swift",
            "ios/Agmente/ServerConfiguration.swift",
            "ios/Agmente/ChatModels.swift",
            "ios/Agmente/PassiveStreamingSettler.swift",
            "ios/Agmente/ServerViewModel.swift",
            "ios/Agmente/ServerViewModel+SessionList.swift",
            "ios/Agmente/ServerViewModel+SessionLifecycle.swift",
            "ios/Agmente/ACPSessionViewModel.swift",
            "ios/Agmente/ACPSessionViewModel+Transcript.swift",
            "ios/Agmente/ACPSessionViewModel+Permissions.swift",
            "ios/Agmente/SessionListProjection.swift",
            "ios/Agmente/HomeSessionListView.swift",
            "ios/Agmente/NewSessionSheet.swift",
            "ios/Agmente/SessionDetailView.swift",
            "ios/Agmente/SessionComposerView.swift",
            "ios/Agmente/WorkingDirectoryPickerSheet.swift",
        ]
        for file in requiredFiles {
            assertExists(file, ac: "SC-AC-009")
        }

        // ServerConnectionSlot must not hold sync fields or 5 dead fields
        let poolText = try String(contentsOf: iosRoot.appendingPathComponent("Agmente/ServerConnectionPool.swift"), encoding: .utf8)
        let slotForbidden = [
            "initialSyncTask",
            "initialSyncGeneration",
            "activeSyncServiceObjectId",
            "syncedServiceObjectId",
            "quotaRefreshTask",
            "pendingNewSessionCwd",
            "pendingSessionLoad",
            "resolvedSessionIds",
            "creatingSessionTasks",
        ]
        for sym in slotForbidden {
            XCTAssertFalse(poolText.contains(sym), "SC-AC-009: ServerConnectionPool.swift must not contain '\(sym)'")
        }

        // ChatMessageCache must have zero reference to ServerViewModel or SessionStorage
        let cacheText = try String(contentsOf: iosRoot.appendingPathComponent("Agmente/ChatMessageCache.swift"), encoding: .utf8)
        XCTAssertFalse(cacheText.contains("ServerViewModel"), "SC-AC-009: ChatMessageCache must not reference ServerViewModel")
        XCTAssertFalse(cacheText.contains("SessionStorage"), "SC-AC-009: ChatMessageCache must not reference SessionStorage")

        // PassiveStreamingSettler must have zero reference to ACPSessionViewModel
        let settlerText = try String(contentsOf: iosRoot.appendingPathComponent("Agmente/PassiveStreamingSettler.swift"), encoding: .utf8)
        XCTAssertFalse(settlerText.contains("ACPSessionViewModel"), "SC-AC-009: PassiveStreamingSettler must not reference ACPSessionViewModel")

        // ConnectionUsageState.unsupported must not exist anywhere
        let quotaStoreText = try String(contentsOf: iosRoot.appendingPathComponent("Agmente/QuotaUsageStore.swift"), encoding: .utf8)
        XCTAssertFalse(quotaStoreText.contains("case unsupported"), "SC-AC-009: ConnectionUsageState.unsupported must be removed")
        let allSwift = allFiles(
            under: iosRoot,
            extensions: ["swift"],
            excludingSubstrings: [".build/", "StripCodexArchitectureAuditTests.swift"]
        )
        let unsupportedHits = scanFiles(allSwift, forForbiddenLiterals: ["ConnectionUsageState.unsupported"])
        XCTAssertTrue(unsupportedHits.isEmpty, "SC-AC-009 ConnectionUsageState.unsupported hits:\n\(unsupportedHits.joined(separator: "\n"))")
    }

    // MARK: - SC-AC-010: Dead code, TD-2 cross-server global reads, and ACPClient 5 blocks removed

    func testSCAC010_DeadCodeCrossServerGlobalReadsAndACPClient5BlocksRemoved() throws {
        // 1. Dead code across ios/
        let allSwift = allFiles(
            under: iosRoot,
            extensions: ["swift"],
            excludingSubstrings: [".build/", "StripCodexArchitectureAuditTests.swift"]
        )
        let deadHits = scanFiles(allSwift, forForbiddenLiterals: [
            "persistActiveServerConfig",
            "isApplyingSelectedServerConfig",
            "sessionSummaryCache",
            "normalizeCorruptedCachedTimestampsIfNeeded",
            "selectedCommandName",
            "effectiveWorkingDirectory",
            "redactedWorkingDirectoryForStorage",
            "handleScenePhaseChanged(isActive:",
        ])
        XCTAssertTrue(deadHits.isEmpty, "SC-AC-010 dead code hits:\n\(deadHits.joined(separator: "\n"))")

        // 2. TD-2 cross-server global reads across the 6 views
        let viewFiles = [
            "Agmente/SessionDetailView.swift",
            "Agmente/SessionComposerView.swift",
            "Agmente/WorkingDirectoryPickerSheet.swift",
            "Agmente/HomeSessionListView.swift",
            "Agmente/NewSessionSheet.swift",
        ]
        let forbiddenViewRegexes: [(String, String)] = [
            ("model\\.selectedServerId", "model.selectedServerId"),
            ("model\\.isPendingSession", "model.isPendingSession"),
            ("model\\.connectionState(?!\\s*\\(for:)", "model.connectionState (unscoped)"),
            ("model\\.currentSessionCwd(?!\\s*\\(for:)", "model.currentSessionCwd (unscoped)"),
            ("model\\.workingDirectory", "model.workingDirectory"),
            ("model\\.usedWorkingDirectoryHistory(?!\\s*\\(for:)", "model.usedWorkingDirectoryHistory (unscoped)"),
            ("model\\.normalizedSessionDirectoryForBrowsing\\(\\)", "model.normalizedSessionDirectoryForBrowsing()"),
            ("model\\.normalizedDefaultDirectoryForBrowsing\\(\\)", "model.normalizedDefaultDirectoryForBrowsing()"),
            ("model\\.readRemoteFile\\((?:(?!serverId:)[^)])*\\)", "model.readRemoteFile without serverId:"),
            ("model\\.listRemoteDirectory\\((?:(?!serverId:)[^)])*\\)", "model.listRemoteDirectory without serverId:"),
            ("model\\.sendSetMode\\((?:(?!serverId:)[^)])*\\)", "model.sendSetMode without serverId:"),
            ("model\\.deleteSession\\((?:(?!serverId:)[^)])*\\)", "model.deleteSession without serverId:"),
            ("model\\.canViewSessionInfo\\((?:(?!serverId:)[^)])*\\)", "model.canViewSessionInfo without serverId:"),
            ("model\\.updatePendingSessionWorkingDirectory\\((?:(?!serverId:)[^)])*\\)", "model.updatePendingSessionWorkingDirectory without serverId:"),
        ]
        var td2Hits: [String] = []
        for rel in viewFiles {
            let text = try String(contentsOf: iosRoot.appendingPathComponent(rel), encoding: .utf8)
            for (pattern, label) in forbiddenViewRegexes {
                if text.range(of: pattern, options: .regularExpression) != nil {
                    td2Hits.append("\(rel): forbidden TD-2 global read '\(label)'")
                }
            }
        }
        // Also check ContentView.swift editServerSheet / showingServerFileBrowser / presentNewSessionSheet for unscoped TD-2 calls
        let contentViewText = try String(contentsOf: iosRoot.appendingPathComponent("Agmente/ContentView.swift"), encoding: .utf8)
        let contentViewForbidden: [(String, String)] = [
            ("model\\.usedWorkingDirectoryHistory(?!\\s*\\(for:)", "model.usedWorkingDirectoryHistory (unscoped)"),
            ("model\\.listRemoteDirectory\\((?:(?!serverId:)[^)])*\\)", "model.listRemoteDirectory without serverId:"),
            ("model\\.readRemoteFile\\((?:(?!serverId:)[^)])*\\)", "model.readRemoteFile without serverId:"),
            ("model\\.connectionState(?!\\s*\\(for:)", "model.connectionState (unscoped)"),
        ]
        for (pattern, label) in contentViewForbidden {
            if contentViewText.range(of: pattern, options: .regularExpression) != nil {
                td2Hits.append("Agmente/ContentView.swift: forbidden TD-2 global read '\(label)'")
            }
        }
        XCTAssertTrue(td2Hits.isEmpty, "SC-AC-010 TD-2 violations:\n\(td2Hits.joined(separator: "\n"))")

        // 3. ACPClient 5 blocks removed from ios/ACPClient/Sources/
        let acpClientSources = allFiles(
            under: iosRoot.appendingPathComponent("ACPClient/Sources"),
            extensions: ["swift"]
        )
        let acpHits = scanFiles(acpClientSources, forForbiddenLiterals: [
            "ACPConnectedProtocol",
            "makeCodexAgentInfo",
            "parseCodexVersion",
            "AgentCapabilityVerification",
            "SemanticVersion",
            "VersionRequirement",
            "requiresUnescapedSlashes",
            "setWithoutEscapingSlashesEnabled",
            "sessionResume",
            "resumingSessions",
            "ACPCapabilityKind",
            ".capabilityConfirmed",
            ".capabilityDisabled",
            "ACPInitializationPayload.capabilities",
        ])
        XCTAssertTrue(acpHits.isEmpty, "SC-AC-010 ACPClient 5-block residuals:\n\(acpHits.joined(separator: "\n"))")
    }

    // MARK: - SC-AC-012: Retained iOS docs updated with zero stale contracts

    func testSCAC012_RetainedDocsUpdatedAndZeroStaleContracts() throws {
        assertDoesNotExist("ios/AppServerClient/AGENTS.md", ac: "SC-AC-012")
        let retainedDocs = [
            "ios/README.md",
            "ios/Agmente/AGENTS.md",
            "ios/ACPClient/AGENTS.md",
            "ios/AgmenteTests/AGENTS.md",
            "ios/AgmenteUITests/AGENTS.md",
        ]
        let forbiddenDocTokens = [
            "AppServerClient",
            "Codex",
            "ServerViewModelProtocol",
            "legacyFallbackConnectionManager",
            "GoferMethods",
            "e2e/scenarios/",
        ]
        var staleHits: [String] = []
        for rel in retainedDocs {
            assertExists(rel, ac: "SC-AC-012")
            let raw = try String(contentsOf: repoRoot.appendingPathComponent(rel), encoding: .utf8)
            // Strip this audit test's own class identifier before scanning for stale protocol contracts.
            let content = raw.replacingOccurrences(of: "StripCodexArchitectureAuditTests", with: "")
            for token in forbiddenDocTokens where content.contains(token) {
                staleHits.append("\(rel) contains stale token '\(token)'")
            }
        }
        XCTAssertTrue(staleHits.isEmpty, "SC-AC-012 retained docs stale contract hits:\n\(staleHits.joined(separator: "\n"))")
    }
}

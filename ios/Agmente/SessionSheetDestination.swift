import Foundation

/// Unified sheet destination for `SessionDetailView` (T7 #衔接点-b).
/// Consolidates T3 session info, T5 directory browser, T6 remote path jump,
/// and T10 Mermaid fullscreen viewer under a single `.sheet(item:)` modifier.
enum SessionSheetDestination: Identifiable, Equatable {
    case sessionInfo(sessionId: String)
    case directoryBrowser(path: String, projectPath: String?)
    case remotePath(id: UUID, initialPath: String, prefersDirectory: Bool, lineAnchorHint: String?, projectPath: String?)
    case mermaidFullscreen(source: String)

    var id: String {
        switch self {
        case .sessionInfo(let sessionId):
            return "sessionInfo:\(sessionId)"
        case .directoryBrowser(let path, let projectPath):
            return "directoryBrowser:\(path):\(projectPath ?? "")"
        case .remotePath(let id, _, _, _, _):
            return "remotePath:\(id.uuidString)"
        case .mermaidFullscreen(let source):
            return "mermaidFullscreen:\(source.hashValue)"
        }
    }
}

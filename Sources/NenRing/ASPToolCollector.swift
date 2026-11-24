import Foundation

/// Reads a validated generated or explicitly imported asptool source and
/// delegates normalization to the streaming parser. The raw file is never
/// copied into the application's history.
struct ASPToolSnapshotCollector: Sendable {
    let parser: ASPToolSnapshotParser

    init(parser: ASPToolSnapshotParser = ASPToolSnapshotParser()) {
        self.parser = parser
    }

    func collect(
        from sourceURL: URL,
        deviceID: String?,
        sourceArtifact: ASPToolSourceArtifact = .extractedASPTool
    ) throws -> ASPToolSnapshotParseResult {
        let resourceValues = try sourceURL.resourceValues(forKeys: [
            .contentModificationDateKey
        ])
        let modifiedAt = resourceValues.contentModificationDate
        let captureQuality: ASPToolCaptureQuality = modifiedAt == nil ? .unknown : .fileMetadata
        return try parser.parse(
            fileURL: sourceURL,
            capturedAt: modifiedAt ?? Date(),
            captureQuality: captureQuality,
            deviceID: deviceID,
            sourceName: sourceURL.lastPathComponent,
            sourceArtifact: sourceArtifact
        )
    }
}

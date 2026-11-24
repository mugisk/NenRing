import Foundation

/// The settings screen can inspect the three artifact families produced by
/// the reviewed standalone probes. This router only classifies a directory by
/// exact filenames; it never scans for arbitrary opcodes or runs a command.
enum ASPDirectArtifactInspectionResult: Sendable {
    case legacy(ASPDirectArtifactInspection)
    case ftl(ASPToolDirectFTLParseResult)
    case bandStats(ASPBandStatsParseResult)
    case opaque(ASPDirectOpaqueInspection)
}

struct ASPDirectArtifactRouter: Sendable {
    func inspect(
        directoryURL: URL,
        deviceID: String? = nil,
        deviceContext: CurrentDeviceContext? = nil,
        parsedAt: Date = Date()
    ) throws -> ASPDirectArtifactInspectionResult {
        let fileManager = FileManager.default
        let ftlPayload = directoryURL.appendingPathComponent("asp-ftl-all.bin")
        if fileManager.fileExists(atPath: ftlPayload.path) {
            let result = try ASPToolDirectFTLArtifactCollector().collect(
                from: directoryURL,
                deviceID: deviceID,
                deviceContext: deviceContext,
                parsedAt: parsedAt
            )
            return .ftl(result)
        }

        let ftlPermPayload = directoryURL.appendingPathComponent("asp-ftl-perm.bin")
        if fileManager.fileExists(atPath: ftlPermPayload.path) {
            let result = try ASPOpaqueArtifactCollector().collectFTL(
                from: directoryURL,
                parsedAt: parsedAt
            )
            return .opaque(.ftl(result))
        }

        let bandPayload = directoryURL.appendingPathComponent("tunnel-0x106.bin")
        if fileManager.fileExists(atPath: bandPayload.path) {
            let result = try ASPBandStatsArtifactCollector().collect(
                from: directoryURL,
                deviceID: deviceID,
                parsedAt: parsedAt
            )
            return .bandStats(result)
        }

        for opcode in [ASPTunnelOpcode.aspExport, ASPTunnelOpcode.bandStats] {
            let payload = directoryURL.appendingPathComponent(
                String(format: "tunnel-0x%03x.bin", opcode.rawValue)
            )
            if fileManager.fileExists(atPath: payload.path) {
                let result = try ASPOpaqueArtifactCollector().collectTunnel(
                    from: directoryURL,
                    parsedAt: parsedAt
                )
                return .opaque(.tunnel(result))
            }
        }

        // A failed private call has metadata but deliberately no payload.
        // Parse only the two reviewed metadata contracts so that those
        // failures remain inspectable without broad opcode or file scans.
        let metadataURL = directoryURL.appendingPathComponent("metadata.txt")
        if fileManager.fileExists(atPath: metadataURL.path) {
            if let measurement = try? ASPToolDirectFTLMetadataParser().parse(fileURL: metadataURL),
               measurement.isReviewedTarget {
                let result = try ASPOpaqueArtifactCollector().collectFTL(
                    from: directoryURL,
                    parsedAt: parsedAt
                )
                return .opaque(.ftl(result))
            }
            if let measurement = try? ASPTunnelMetadataParser().parse(fileURL: metadataURL),
               measurement.build == "25G83",
               measurement.controller == "AppleANS3NVMeController",
               measurement.selector == 9 {
                let result = try ASPOpaqueArtifactCollector().collectTunnel(
                    from: directoryURL,
                    parsedAt: parsedAt
                )
                return .opaque(.tunnel(result))
            }
        }

        return .legacy(try ASPDirectArtifactInspector().inspect(directoryURL: directoryURL))
    }
}

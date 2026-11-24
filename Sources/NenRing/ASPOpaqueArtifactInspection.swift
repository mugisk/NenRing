import Foundation

struct ASPToolDirectFTLOpaqueInspection: Equatable, Sendable {
    let measurement: ASPToolDirectFTLMeasurement
    let payloadByteCount: Int?
    let parsedAt: Date
    let warnings: [String]
}

struct ASPTunnelOpaqueInspection: Equatable, Sendable {
    let measurement: ASPTunnelMeasurement
    let payloadByteCount: Int?
    let parsedAt: Date
    let warnings: [String]
}

enum ASPDirectOpaqueInspection: Sendable {
    case ftl(ASPToolDirectFTLOpaqueInspection)
    case tunnel(ASPTunnelOpaqueInspection)
}

enum ASPOpaqueArtifactCollectorError: LocalizedError, Equatable, Sendable {
    case unsupportedTarget
    case missingPayload(URL)
    case responseSizeMismatch(expectedBytes: Int, actualBytes: Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedTarget:
            return "opaque ASP artifactが確認済みの対象ではありません"
        case let .missingPayload(url):
            return "opaque ASP payloadがありません: \(url.path)"
        case let .responseSizeMismatch(expectedBytes, actualBytes):
            return "opaque ASP payloadのサイズがmetadataと一致しません（期待 \(expectedBytes) / 実際 \(actualBytes)）"
        }
    }
}

/// Inspects a private artifact without interpreting its unconfirmed binary
/// format. This is used for FTL `perm` and the two tunnel commands that have
/// not yet been mapped to a record contract.
struct ASPOpaqueArtifactCollector: Sendable {
    func collectFTL(
        from directoryURL: URL,
        parsedAt: Date = Date()
    ) throws -> ASPToolDirectFTLOpaqueInspection {
        let metadataURL = directoryURL.appendingPathComponent("metadata.txt")
        let measurement = try ASPToolDirectFTLMetadataParser().parse(fileURL: metadataURL)
        guard measurement.isReviewedTarget else {
            throw ASPOpaqueArtifactCollectorError.unsupportedTarget
        }
        let payloadURL = directoryURL.appendingPathComponent("asp-ftl-\(measurement.kind.rawValue).bin")
        let payloadByteCount: Int?
        if measurement.isSuccessfulRead {
            payloadByteCount = try requiredPayloadByteCount(
                at: payloadURL,
                expectedBytes: measurement.responseBytes
            )
        } else {
            // The probe deliberately keeps metadata even when the private
            // call fails, but does not create a binary file in that case.
            // Preserve that failure as a diagnostic rather than turning it
            // into a missing-artifact error or a zero-valued counter.
            payloadByteCount = nil
        }
        return ASPToolDirectFTLOpaqueInspection(
            measurement: measurement,
            payloadByteCount: payloadByteCount,
            parsedAt: parsedAt,
            warnings: [
                "FTL \(measurement.kind.rawValue) payloadの存在・サイズ・取得metadataのみを確認しました",
                "形式未確認のためkey、単位、counter意味を解釈していません",
                measurement.isSuccessfulRead
                    ? "取得成功ですが、payloadの値はまだ正規化していません"
                    : "取得失敗のためpayloadを値として扱っていません",
                "履歴・容量換算・寿命予測へ投入していません"
            ]
        )
    }

    func collectTunnel(
        from directoryURL: URL,
        parsedAt: Date = Date()
    ) throws -> ASPTunnelOpaqueInspection {
        let metadataURL = directoryURL.appendingPathComponent("metadata.txt")
        let measurement = try ASPTunnelMetadataParser().parse(fileURL: metadataURL)
        guard measurement.build == "25G83",
              measurement.controller == "AppleANS3NVMeController",
              measurement.selector == 9 else {
            throw ASPOpaqueArtifactCollectorError.unsupportedTarget
        }
        let payloadURL = directoryURL.appendingPathComponent(
            String(format: "tunnel-0x%03x.bin", measurement.opcode.rawValue)
        )
        let payloadByteCount: Int?
        if measurement.outcome == .readFailed {
            // Failed tunnel reads retain metadata but intentionally do not
            // retain a raw payload. Keep the failure visible without
            // pretending that zero bytes is a valid response.
            payloadByteCount = nil
        } else {
            payloadByteCount = try requiredPayloadByteCount(
                at: payloadURL,
                expectedBytes: measurement.responseBytes
            )
        }
        var warnings = [
            "tunnel opcode 0x\(String(format: "%03x", measurement.opcode.rawValue)) payloadの存在・サイズ・取得metadataのみを確認しました",
            "形式未確認のためrecord、単位、counter意味を解釈していません",
            measurement.outcome == .readFailed
                ? "取得失敗のためpayloadを値として扱っていません"
                : "取得結果は保持しましたが、payloadの値はまだ正規化していません",
            "履歴・容量換算・寿命予測へ投入していません"
        ]
        if measurement.sizeQueryResultCode == 0xe00002c1 ||
            measurement.readResultCode == 0xe00002c1 {
            warnings.insert(
                "AppleANS3 tunnelは管理者権限が必要です。再取得時にmacOSの管理者認証を許可してください",
                at: 0
            )
        } else if measurement.isDeviceRejectedOpaqueTunnel {
            warnings.insert(
                "euid=0で管理者認証済みですが、AppleANS3がこのopcodeをdevice errorとして拒否しました。権限不足ではなく、現行buildの直接tunnel経路からはpayloadを取得できません",
                at: 0
            )
        }

        return ASPTunnelOpaqueInspection(
            measurement: measurement,
            payloadByteCount: payloadByteCount,
            parsedAt: parsedAt,
            warnings: warnings
        )
    }

    private func requiredPayloadByteCount(at url: URL, expectedBytes: Int) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ASPOpaqueArtifactCollectorError.missingPayload(url)
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count == expectedBytes else {
            throw ASPOpaqueArtifactCollectorError.responseSizeMismatch(
                expectedBytes: expectedBytes,
                actualBytes: data.count
            )
        }
        return data.count
    }
}

import Foundation
import Security

/// Evidence returned after a probe has passed the runtime code-signature
/// check.  The value is intentionally kept separate from probe output: it is
/// an execution-gate result, not telemetry from AppleANS3.
struct ASPProbeSignatureEvidence: Equatable, Sendable {
    let identifier: String
    let teamIdentifier: String?
    let isAdHoc: Bool
}

enum ASPProbeSignatureError: LocalizedError, Equatable, Sendable {
    case outsideBundle(String)
    case notRegularExecutable(String)
    case unprotectedForAdministrator(String)
    case createFailed(Int32)
    case invalidSignature(Int32)
    case signingInformationUnavailable(Int32)
    case identifierMismatch(expected: String, actual: String?)
    case teamIdentifierMismatch(expected: String?, actual: String?)

    var errorDescription: String? {
        switch self {
        case let .outsideBundle(path):
            return "probeがアプリ内の固定ASPProbesディレクトリ外にあります: \(path)"
        case let .notRegularExecutable(path):
            return "probeが通常の実行ファイルではありません: \(path)"
        case let .unprotectedForAdministrator(path):
            return "管理者実行にはroot所有かつ利用者以外から書換不能な署名済みprobeが必要です: \(path)"
        case let .createFailed(status):
            return "probeのコード署名を読み込めませんでした（OSStatus \(status)）"
        case let .invalidSignature(status):
            return "probeのstrictコード署名検証に失敗しました（OSStatus \(status)）。管理者実行を中止しました"
        case let .signingInformationUnavailable(status):
            return "probeの署名情報を読み込めませんでした（OSStatus \(status)）"
        case let .identifierMismatch(expected, actual):
            let actualText = actual ?? "なし"
            return "probeの署名識別子が一致しません（expected=\(expected), actual=\(actualText)）"
        case let .teamIdentifierMismatch(expected, actual):
            let expectedText = expected ?? "なし"
            let actualText = actual ?? "なし"
            return "probeとアプリのTeam Identifierが一致しません（app=\(expectedText), probe=\(actualText)）"
        }
    }
}

/// Verifies the exact executable that is about to be passed to the normal or
/// administrator process runner.  The build currently uses an ad-hoc
/// signature, so this provides tamper evidence and fixed identity/path
/// checks; a Developer ID build can additionally expose a Team Identifier.
struct ASPProbeSignatureVerifier: Sendable {
    private let allowUnsignedForTesting: Bool

    init(allowUnsignedForTesting: Bool = false) {
        self.allowUnsignedForTesting = allowUnsignedForTesting
    }

    func verify(
        executableURL: URL,
        expectedIdentifier: String,
        bundleURL: URL?,
        requiresAdministrator: Bool
    ) throws -> ASPProbeSignatureEvidence {
        let probeURL = executableURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedBundleURL = bundleURL?.resolvingSymlinksInPath().standardizedFileURL

        if let resolvedBundleURL,
           !Self.isFixedProbeLocation(probeURL, bundleURL: resolvedBundleURL) {
            throw ASPProbeSignatureError.outsideBundle(probeURL.path)
        }

        guard FileManager.default.isExecutableFile(atPath: probeURL.path),
              isRegularFile(probeURL) else {
            throw ASPProbeSignatureError.notRegularExecutable(probeURL.path)
        }

        if requiresAdministrator {
            try validateAdministratorProtection(probeURL, bundleURL: resolvedBundleURL)
        }

        if allowUnsignedForTesting {
            return ASPProbeSignatureEvidence(
                identifier: expectedIdentifier,
                teamIdentifier: nil,
                isAdHoc: true
            )
        }

        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            probeURL as CFURL,
            SecCSFlags(),
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            throw ASPProbeSignatureError.createFailed(Int32(createStatus))
        }

        let validityStatus = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        )
        guard validityStatus == errSecSuccess else {
            throw ASPProbeSignatureError.invalidSignature(Int32(validityStatus))
        }

        var signingInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        )
        guard informationStatus == errSecSuccess,
              let signingInformation,
              let dictionary = signingInformation as? [String: Any] else {
            throw ASPProbeSignatureError.signingInformationUnavailable(Int32(informationStatus))
        }

        let actualIdentifier = dictionary[kSecCodeInfoIdentifier as String] as? String
        guard actualIdentifier == expectedIdentifier else {
            throw ASPProbeSignatureError.identifierMismatch(
                expected: expectedIdentifier,
                actual: actualIdentifier
            )
        }

        let teamIdentifier = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        if let resolvedBundleURL {
            let bundleTeamIdentifier = try signingTeamIdentifier(for: resolvedBundleURL)
            if bundleTeamIdentifier != teamIdentifier,
               bundleTeamIdentifier != nil || teamIdentifier != nil {
                throw ASPProbeSignatureError.teamIdentifierMismatch(
                    expected: bundleTeamIdentifier,
                    actual: teamIdentifier
                )
            }
        }
        return ASPProbeSignatureEvidence(
            identifier: actualIdentifier ?? expectedIdentifier,
            teamIdentifier: teamIdentifier,
            isAdHoc: teamIdentifier == nil
        )
    }

    static func isFixedProbeLocation(_ probeURL: URL, bundleURL: URL) -> Bool {
        let expectedDirectory = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("ASPProbes", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        return probeURL.deletingLastPathComponent().path == expectedDirectory.path
    }

    private func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return false
        }
        return attributes[.type] as? FileAttributeType == .typeRegular
    }

    private func validateAdministratorProtection(_ probeURL: URL, bundleURL: URL?) throws {
        guard let bundleURL else {
            throw ASPProbeSignatureError.unprotectedForAdministrator(probeURL.path)
        }

        var currentURL = probeURL
        let rootPath = URL(fileURLWithPath: "/").path
        while true {
            try validateRootOwnedAndNotGroupWritable(currentURL)
            if currentURL.path == rootPath {
                break
            }
            currentURL.deleteLastPathComponent()
        }

        // This explicit containment check remains even though the caller also
        // performs it. It makes the privileged trust boundary self-contained.
        guard Self.isFixedProbeLocation(probeURL, bundleURL: bundleURL) else {
            throw ASPProbeSignatureError.outsideBundle(probeURL.path)
        }
    }

    private func signingTeamIdentifier(for url: URL) throws -> String? {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(),
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            throw ASPProbeSignatureError.createFailed(Int32(createStatus))
        }
        let validityStatus = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        )
        guard validityStatus == errSecSuccess else {
            throw ASPProbeSignatureError.invalidSignature(Int32(validityStatus))
        }
        var signingInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        )
        guard informationStatus == errSecSuccess,
              let signingInformation,
              let dictionary = signingInformation as? [String: Any] else {
            throw ASPProbeSignatureError.signingInformationUnavailable(Int32(informationStatus))
        }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private func validateRootOwnedAndNotGroupWritable(_ url: URL) throws {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let ownerID = (attributes[.ownerAccountID] as? NSNumber)?.intValue,
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              ownerID == 0,
              permissions & 0o022 == 0 else {
            throw ASPProbeSignatureError.unprotectedForAdministrator(url.path)
        }
    }
}

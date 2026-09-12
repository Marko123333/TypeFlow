import CryptoKit
import Foundation
import Security

struct UpdateManifest: Decodable, Equatable {
    let version: String
    let url: String
    let notes: String?
    let sha256: String?
}

enum UpdateVersion {
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidate = parse(candidate),
              let current = parse(current)
        else { return false }
        return compare(candidate, current) == .orderedDescending
    }

    static func isValid(_ value: String) -> Bool {
        parse(value) != nil
    }

    private static func parse(_ value: String) -> (core: [Int], prerelease: String)? {
        guard value.count <= 32,
              value.range(
                of: "^[0-9]+(\\.[0-9]+){1,3}[a-z]?$",
                options: .regularExpression
              ) != nil
        else { return nil }

        var value = Substring(value)
        var prerelease = ""
        if let last = value.last, last.isLetter {
            prerelease = String(last).lowercased()
            value = value.dropLast()
        }
        let components = value.split(separator: ".")
        var core: [Int] = []
        for component in components {
            guard component.count <= 9,
                  let number = Int(component),
                  number <= 999_999_999
            else { return nil }
            core.append(number)
        }
        return (core, prerelease)
    }

    private static func compare(
        _ left: (core: [Int], prerelease: String),
        _ right: (core: [Int], prerelease: String)
    ) -> ComparisonResult {
        for index in 0..<max(left.core.count, right.core.count) {
            let leftPart = index < left.core.count ? left.core[index] : 0
            let rightPart = index < right.core.count ? right.core[index] : 0
            if leftPart != rightPart {
                return leftPart < rightPart ? .orderedAscending : .orderedDescending
            }
        }
        if left.prerelease == right.prerelease { return .orderedSame }
        if left.prerelease.isEmpty { return .orderedDescending }
        if right.prerelease.isEmpty { return .orderedAscending }
        return left.prerelease < right.prerelease ? .orderedAscending : .orderedDescending
    }
}

/// Verifies update manifests independently from the hosting account. The
/// private key stays outside Git; only this public certificate is shipped in
/// the application. A compromised GitHub repository therefore cannot publish
/// a trusted manifest without the LocalSwitcher signing key.
enum UpdateManifestVerifier {
    static let trustedCertificateSHA1 = "ba582d2e25c17fad3524b3c3caed3748816d2e8a"
    static let trustedCertificateSHA256 = "19c8caec20337d7749f5760844b6011364f463c0890268753eae8e6334318f30"

    private static let trustedCertificatePEM = """
    -----BEGIN CERTIFICATE-----
    MIIDfzCCAmegAwIBAgIJAMtPYhLOA+ciMA0GCSqGSIb3DQEBCwUAMEIxKDAmBgNV
    BAMMH0xvY2FsU3dpdGNoZXIgTG9jYWwgRGV2ZWxvcG1lbnQxFjAUBgNVBAoMDUxv
    Y2FsU3dpdGNoZXIwHhcNMjYwOTEwMDg0NjUwWhcNMzYwOTA3MDg0NjUwWjBCMSgw
    JgYDVQQDDB9Mb2NhbFN3aXRjaGVyIExvY2FsIERldmVsb3BtZW50MRYwFAYDVQQK
    DA1Mb2NhbFN3aXRjaGVyMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA
    lJVWtgVLD3cZEl5aaXI7qYeKzKoVxOC9x8OqqXkFwWPxtVTZJKjwnDK1oqhp1a+T
    7XG52FYAlZ2pgklwxkS3fAkpfQDcBFBOAj/i7TIdHHcRE8i4UW5p4rH7IiYUlhpC
    m9zOElCD+BudPl/XQyNKxPN3aKnOqjUQQtztHgpev0NhW5cG0ZM8jrxLde4vyoZ2
    lj0doNkXf4f3tXUFvnuiyPppI8KREaPAnBg+8t9Mst+J+7Mcqo0iXF1a9JB0kcRn
    gOrEgJGgkI1hSSfRrcARvpWru4j2Afkle7TZMe0dbzzrWfw5EX3kMkwxPwGI1voe
    cLQIP6gOHb+OIxSdQJ5xzwIDAQABo3gwdjAPBgNVHRMBAf8EBTADAQH/MA4GA1Ud
    DwEB/wQEAwIChDATBgNVHSUEDDAKBggrBgEFBQcDAzAdBgNVHQ4EFgQUbBvs52gq
    jGtyodovN2k33u3K24IwHwYDVR0jBBgwFoAUbBvs52gqjGtyodovN2k33u3K24Iw
    DQYJKoZIhvcNAQELBQADggEBACeqi+k+U22GQArGpY+Z9HjEaqwOqhpx0O1/Wo04
    5QhBn8+7Dd81bJrda5LpMOp0D36pbThgHihhYhlnd8ZUGZED/ddgmgK3AAQvdsQw
    TIIt50ZwZifIAIrCvZ3mPHTFlIP66XujTHkr4tQL1wKp7pJCPh0tsK+6QWSOYkjy
    lZymAGOG89LTZeoMbNhk/uLXjG9Zp8QE9hrOEyQ3WbSaTXnFdCM/hDSMz8qdnw0H
    UYHlvr8Jm4pqQ1Oc97GNMzaIrzlVmikd6OqwBvxT0WBcGzPkeTJUJd/NSTvF9vyh
    20h7pSqVDBRcE6Jnowkuq7Zi4o5WbuUu9W490LoU0mcy3Y4=
    -----END CERTIFICATE-----
    """

    static let trustedCertificateData: Data = {
        guard let data = decodePEM(trustedCertificatePEM),
              sha256(data) == trustedCertificateSHA256
        else { preconditionFailure("Embedded update certificate is corrupted") }
        return data
    }()

    static func verify(manifestData: Data, signatureData: Data) -> UpdateManifest? {
        verify(
            manifestData: manifestData,
            signatureData: signatureData,
            certificatePEM: trustedCertificatePEM
        )
    }

    static func verify(
        manifestData: Data,
        signatureData: Data,
        certificatePEM: String
    ) -> UpdateManifest? {
        guard let certificateData = decodePEM(certificatePEM),
              sha256(certificateData) == trustedCertificateSHA256,
              let certificate = SecCertificateCreateWithData(nil, certificateData as CFData),
              let publicKey = SecCertificateCopyKey(certificate)
        else { return nil }

        return verify(manifestData: manifestData, signatureData: signatureData, publicKey: publicKey)
    }

    static func verify(
        manifestData: Data,
        signatureData: Data,
        publicKey: SecKey
    ) -> UpdateManifest? {
        guard let signature = decodeSignature(signatureData),
              signature.count == SecKeyGetBlockSize(publicKey),
              SecKeyIsAlgorithmSupported(publicKey, .verify, .rsaSignatureMessagePKCS1v15SHA256)
        else { return nil }

        var error: Unmanaged<CFError>?
        guard SecKeyVerifySignature(
            publicKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            manifestData as CFData,
            signature as CFData,
            &error
        ) else { return nil }

        guard let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: manifestData),
              UpdateVersion.isValid(manifest.version),
              isValidProjectURL(manifest.url),
              manifest.notes?.count ?? 0 <= 20_000,
              isValidOptionalSHA256(manifest.sha256)
        else { return nil }
        return manifest
    }

    private static func decodePEM(_ pem: String) -> Data? {
        let body = pem
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
        return Data(base64Encoded: body, options: .ignoreUnknownCharacters)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func decodeSignature(_ data: Data) -> Data? {
        guard let encoded = String(data: data, encoding: .utf8) else { return nil }
        let whitespace = CharacterSet.whitespacesAndNewlines
        let invalid = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
            .union(whitespace)
            .inverted
        guard encoded.rangeOfCharacter(from: invalid) == nil else { return nil }
        let compact = encoded.components(separatedBy: whitespace).joined()
        guard !compact.isEmpty else { return nil }
        return Data(base64Encoded: compact)
    }

    private static func isValidProjectURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
              url.scheme == "https",
              url.host?.lowercased() == "github.com"
        else { return false }
        let acceptedRepositories = ["TypeFlow", "LocalSwitcher"]
        return acceptedRepositories.contains { repository in
            url.path == "/Marko123333/\(repository)"
                || url.path.hasPrefix("/Marko123333/\(repository)/")
        }
    }

    private static func isValidOptionalSHA256(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil
    }
}

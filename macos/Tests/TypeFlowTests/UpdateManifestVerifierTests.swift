import Foundation
import Security
import Testing
@testable import TypeFlow

@Suite("Signed update manifest")
struct UpdateManifestVerifierTests {
    @Test func versionComparisonNeverDowngrades() {
        #expect(UpdateVersion.isNewer("0.1.11", than: "0.1.10"))
        #expect(UpdateVersion.isNewer("0.1.11b", than: "0.1.11a"))
        #expect(UpdateVersion.isNewer("0.1.11", than: "0.1.11b"))
        #expect(!UpdateVersion.isNewer("0.1.10", than: "0.1.11"))
        #expect(!UpdateVersion.isNewer("0.1.11a", than: "0.1.11"))
        #expect(!UpdateVersion.isNewer("0.1.11", than: "0.1.11"))
        #expect(!UpdateVersion.isNewer("999999999999999999.1", than: "0.1.11"))
        #expect(!UpdateVersion.isNewer("0.1.12", than: "not-a-version"))
    }

    @Test func releaseUsesStablePlatformFilenameInsideVersionedTag() {
        #expect(SettingsManager.releaseDMGFilename(version: "0.2.0") == "LocalSwitcher-0.2.0.dmg")
        #expect(SettingsManager.releaseDMGURL(version: "0.2.0") ==
            "https://github.com/Marko123333/TypeFlow/releases/download/v0.2.0/LocalSwitcher-0.2.0.dmg")
    }

    @Test func repositoryFeedsHaveValidProductionSignatures() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for name in ["version.json", "version-beta.json"] {
            let manifestURL = repository.appendingPathComponent(name)
            let signatureURL = repository.appendingPathComponent(name + ".sig")
            let verified = UpdateManifestVerifier.verify(
                manifestData: try Data(contentsOf: manifestURL),
                signatureData: try Data(contentsOf: signatureURL)
            )
            #expect(verified != nil)
        }
    }

    @Test func acceptsAuthenticManifest() throws {
        let key = try makeKey()
        let data = validManifest()
        let signature = try sign(data, with: key)

        let manifest = UpdateManifestVerifier.verify(
            manifestData: data,
            signatureData: signature,
            publicKey: try publicKey(for: key)
        )

        #expect(manifest?.version == "0.1.11")
        #expect(manifest?.sha256 == String(repeating: "a", count: 64))
    }

    @Test func acceptsCurrentAndLegacyRepositoryURLs() throws {
        let key = try makeKey()
        let publicKey = try publicKey(for: key)
        for url in [
            "https://github.com/Marko123333/TypeFlow",
            "https://github.com/Marko123333/LocalSwitcher",
        ] {
            let data = manifest(
                version: "0.2.0",
                url: url,
                sha256: String(repeating: "a", count: 64)
            )
            #expect(UpdateManifestVerifier.verify(
                manifestData: data,
                signatureData: try sign(data, with: key),
                publicKey: publicKey
            ) != nil)
        }
    }

    @Test func rejectsTamperedManifest() throws {
        let key = try makeKey()
        let original = validManifest()
        let signature = try sign(original, with: key)
        let tampered = Data(String(decoding: original, as: UTF8.self)
            .replacingOccurrences(of: "0.1.11", with: "9.9.9").utf8)

        #expect(UpdateManifestVerifier.verify(
            manifestData: tampered,
            signatureData: signature,
            publicKey: try publicKey(for: key)
        ) == nil)
    }

    @Test func rejectsSignatureFromAnotherKey() throws {
        let trustedKey = try makeKey()
        let attackerKey = try makeKey()
        let data = validManifest()

        #expect(UpdateManifestVerifier.verify(
            manifestData: data,
            signatureData: try sign(data, with: attackerKey),
            publicKey: try publicKey(for: trustedKey)
        ) == nil)
    }

    @Test func rejectsGarbageAppendedToSignature() throws {
        let key = try makeKey()
        let data = validManifest()
        var signature = try sign(data, with: key)
        signature.append(contentsOf: Data("<script>".utf8))

        #expect(UpdateManifestVerifier.verify(
            manifestData: data,
            signatureData: signature,
            publicKey: try publicKey(for: key)
        ) == nil)
    }

    @Test func rejectsUnsafeOrMalformedSignedMetadata() throws {
        let key = try makeKey()
        let publicKey = try publicKey(for: key)
        let cases = [
            manifest(version: "../../Applications/Evil", url: "https://github.com/Marko123333/TypeFlow", sha256: String(repeating: "a", count: 64)),
            manifest(version: "999999999999999999.1", url: "https://github.com/Marko123333/TypeFlow", sha256: String(repeating: "a", count: 64)),
            manifest(version: "0.1.11", url: "http://github.com/Marko123333/TypeFlow", sha256: String(repeating: "a", count: 64)),
            manifest(version: "0.1.11", url: "https://evil.example/TypeFlow", sha256: String(repeating: "a", count: 64)),
            manifest(version: "0.1.11", url: "https://github.com/Marko123333/TypeFlow", sha256: "not-a-hash"),
        ]

        for data in cases {
            #expect(UpdateManifestVerifier.verify(
                manifestData: data,
                signatureData: try sign(data, with: key),
                publicKey: publicKey
            ) == nil)
        }
    }

    @Test func boundedDownloaderCancelsOversizedResponse() async throws {
        let limiter = BoundedDownloader(maximumBytes: 16)
        #expect(!limiter.exceedsLimit(totalBytesWritten: 16, totalBytesExpectedToWrite: -1))
        #expect(limiter.exceedsLimit(totalBytesWritten: 17, totalBytesExpectedToWrite: -1))
        #expect(limiter.exceedsLimit(totalBytesWritten: 0, totalBytesExpectedToWrite: 17))

        guard let fixture = ProcessInfo.processInfo.environment["LOCALSWITCHER_OVERSIZE_URL"],
              let url = URL(string: fixture)
        else { return }

        do {
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("TypeFlow-oversize-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: destination) }
            _ = try await limiter.download(
                for: URLRequest(url: url),
                to: destination
            )
            Issue.record("Oversized response was not cancelled")
        } catch {
            #expect(error is BoundedDownloadError)
        }
    }

    /// Optional integration fixture used by the security release audit. It proves
    /// that the production verifier accepts a correctly sealed app even when its
    /// self-signed certificate is not trusted by the user's Keychain.
    @Test func validatesExternalUntrustedSelfSignedFixtureWhenProvided() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let appPath = environment["LOCALSWITCHER_TEST_APP"],
              let certificatePath = environment["LOCALSWITCHER_TEST_CERT_DER"],
              let certificateSHA1 = environment["LOCALSWITCHER_TEST_CERT_SHA1"]
        else { return }

        let appURL = URL(fileURLWithPath: appPath)
        let certificateData = try Data(contentsOf: URL(fileURLWithPath: certificatePath))
        #expect(ApplicationSignatureVerifier.verify(
            appURL: appURL,
            expectedCertificateData: certificateData,
            expectedCertificateSHA1: certificateSHA1
        ))

        let tamperedURL = appURL.deletingLastPathComponent().appendingPathComponent("Tampered.app")
        try FileManager.default.copyItem(at: appURL, to: tamperedURL)
        let plistURL = tamperedURL.appendingPathComponent("Contents/Info.plist")
        var plist = try Data(contentsOf: plistURL)
        plist.append(0)
        try plist.write(to: plistURL)
        #expect(!ApplicationSignatureVerifier.verify(
            appURL: tamperedURL,
            expectedCertificateData: certificateData,
            expectedCertificateSHA1: certificateSHA1
        ))
    }

    private func validManifest() -> Data {
        manifest(
            version: "0.1.11",
            url: "https://github.com/Marko123333/TypeFlow/releases/tag/v0.1.11",
            sha256: String(repeating: "a", count: 64)
        )
    }

    private func manifest(version: String, url: String, sha256: String) -> Data {
        Data("""
        {"version":"\(version)","url":"\(url)","notes":"Security update","sha256":"\(sha256)"}
        """.utf8)
    }

    private func makeKey() throws -> SecKey {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
        ]
        return try #require(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
    }

    private func publicKey(for privateKey: SecKey) throws -> SecKey {
        try #require(SecKeyCopyPublicKey(privateKey))
    }

    private func sign(_ data: Data, with key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        let signature = SecKeyCreateSignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            data as CFData,
            &error
        ) as Data?
        let raw = try #require(signature)
        return Data(raw.base64EncodedString(options: .endLineWithLineFeed).utf8)
    }
}

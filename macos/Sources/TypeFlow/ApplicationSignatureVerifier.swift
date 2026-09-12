import Foundation
import Security

/// Validates both the cryptographic code seal and the exact signing certificate.
/// The SHA-1 requirement is retained because that is the hash format supported by
/// Apple's code-requirement language; an exact DER comparison removes SHA-1 as the
/// actual trust boundary.
enum ApplicationSignatureVerifier {
    static func verify(
        appURL: URL,
        expectedIdentifier: String = "com.marko.localswitcher.app",
        expectedCertificateData: Data = UpdateManifestVerifier.trustedCertificateData,
        expectedCertificateSHA1: String = UpdateManifestVerifier.trustedCertificateSHA1
    ) -> Bool {
        let requirementText = "identifier \"\(expectedIdentifier)\" and certificate leaf = H\"\(expectedCertificateSHA1)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementText as CFString,
            [],
            &requirement
        ) == errSecSuccess, let requirement else { return false }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &code) == errSecSuccess,
              let code else { return false }

        // Public SecCSFlags from SecStaticCode.h: validate all architectures,
        // nested code, strict bundle structure, symlink restrictions, and the
        // app-like layout. This verifies the executable and every sealed resource.
        let validationFlags = SecCSFlags(rawValue: 1 | 8 | 16 | 128 | 256)
        var validationError: Unmanaged<CFError>?
        guard SecStaticCodeCheckValidityWithErrors(
            code,
            validationFlags,
            requirement,
            &validationError
        ) == errSecSuccess else { return false }

        // kSecCSSigningInformation = 1 << 1. Compare the complete leaf
        // certificate, not only its SHA-1 fingerprint used by the requirement.
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: 1 << 1),
            &signingInformation
        ) == errSecSuccess,
              let dictionary = signingInformation as? [CFString: Any],
              let certificates = dictionary[kSecCodeInfoCertificates] as? [SecCertificate],
              let leaf = certificates.first,
              SecCertificateCopyData(leaf) as Data == expectedCertificateData
        else { return false }

        return true
    }
}

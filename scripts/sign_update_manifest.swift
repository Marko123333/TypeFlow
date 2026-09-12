#!/usr/bin/env swift

import CryptoKit
import Foundation
import Security

private let identityName = "LocalSwitcher Local Development"
private let expectedCertificateSHA1 = "ba582d2e25c17fad3524b3c3caed3748816d2e8a"
private let expectedCertificateSHA256 = "19c8caec20337d7749f5760844b6011364f463c0890268753eae8e6334318f30"

private struct ReleaseManifest: Decodable {
    let version: String
    let build: String
    let url: String
    let notes: String?
    let sha256: String
    let public_sha256: String?
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

private func signingIdentity() -> SecIdentity {
    let query: [CFString: Any] = [
        kSecClass: kSecClassIdentity,
        kSecAttrLabel: identityName,
        kSecReturnRef: true,
        kSecMatchLimit: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let identity = result as! SecIdentity? else {
        fail("code-signing identity '\(identityName)' is unavailable (status \(status))")
    }

    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
          let certificate else {
        fail("cannot read the signing certificate")
    }
    let certificateData = SecCertificateCopyData(certificate) as Data
    let sha1 = Insecure.SHA1.hash(data: certificateData)
        .map { String(format: "%02x", $0) }
        .joined()
    let sha256 = SHA256.hash(data: certificateData)
        .map { String(format: "%02x", $0) }
        .joined()
    guard sha1 == expectedCertificateSHA1,
          sha256 == expectedCertificateSHA256 else {
        fail("identity name matches, but certificate fingerprint is not trusted")
    }
    return identity
}

private func sign(_ manifestURL: URL, with identity: SecIdentity) {
    guard manifestURL.pathExtension == "json" else {
        fail("manifest must be a .json file: \(manifestURL.path)")
    }
    guard let data = try? Data(contentsOf: manifestURL),
          data.count <= 64 * 1024,
          let manifest = try? JSONDecoder().decode(ReleaseManifest.self, from: data),
          manifest.version.count <= 32,
          manifest.version.range(
            of: "^[0-9]+(\\.[0-9]+){1,3}[a-z]?$",
            options: .regularExpression
          ) != nil,
          manifest.version.split(separator: ".").allSatisfy({ component in
            let digits = component.last?.isLetter == true ? component.dropLast() : component[...]
            return digits.count <= 9 && Int(digits) != nil
          }),
          !manifest.build.isEmpty,
          manifest.build.count <= 9,
          manifest.build.allSatisfy(\.isNumber),
          let projectURL = URL(string: manifest.url),
          projectURL.scheme == "https",
          projectURL.host?.lowercased() == "github.com",
          ["TypeFlow", "LocalSwitcher"].contains(where: { repository in
              projectURL.path == "/Marko123333/\(repository)"
                  || projectURL.path.hasPrefix("/Marko123333/\(repository)/")
          }),
          manifest.notes?.count ?? 0 <= 20_000,
          manifest.sha256.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil,
          manifest.public_sha256 == nil
            || manifest.public_sha256?.range(
                of: "^[0-9a-fA-F]{64}$",
                options: .regularExpression
            ) != nil
    else {
        fail("manifest is missing, too large, or invalid JSON: \(manifestURL.path)")
    }

    var privateKey: SecKey?
    guard SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess,
          let privateKey,
          SecKeyIsAlgorithmSupported(privateKey, .sign, .rsaSignatureMessagePKCS1v15SHA256)
    else { fail("the identity does not provide a usable RSA signing key") }

    var error: Unmanaged<CFError>?
    guard let signature = SecKeyCreateSignature(
        privateKey,
        .rsaSignatureMessagePKCS1v15SHA256,
        data as CFData,
        &error
    ) as Data? else {
        fail("manifest signing failed: \(error?.takeRetainedValue().localizedDescription ?? "unknown error")")
    }
    guard let publicKey = SecKeyCopyPublicKey(privateKey),
          SecKeyVerifySignature(
            publicKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            data as CFData,
            signature as CFData,
            &error
          ) else {
        fail("signature self-check failed")
    }

    let signatureURL = URL(fileURLWithPath: manifestURL.path + ".sig")
    let encoded = signature.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
    do {
        try Data(encoded.utf8).write(to: signatureURL, options: .atomic)
        print("Signed \(manifestURL.lastPathComponent) -> \(signatureURL.lastPathComponent)")
    } catch {
        fail("cannot write \(signatureURL.path): \(error.localizedDescription)")
    }
}

let arguments = CommandLine.arguments.dropFirst()
guard !arguments.isEmpty else {
    fail("usage: scripts/sign_update_manifest.swift version.json [version-beta.json]")
}
let identity = signingIdentity()
for path in arguments {
    sign(URL(fileURLWithPath: path).standardizedFileURL, with: identity)
}

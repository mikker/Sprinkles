import Defaults
import Foundation
import Security
import os

class SprinklesCertificate {
  static let dir = "\(NSHomeDirectory())/Certs"
  static let scriptPath = Bundle.main.path(forResource: "gen_cert", ofType: "sh")!
  static let caPath = "\(dir)/ca.der"
  static let keyPath = "\(dir)/key.pem"
  static let certPath = "\(dir)/cert.pem"
  static let p12Path = "\(dir)/identity.p12"
  static let versionPath = "\(dir)/version"

  /// Bump when gen_cert.sh changes in a way that requires regenerating existing certs.
  static let currentVersion = 2
  static let renewalWindow: TimeInterval = 30 * 24 * 60 * 60

  static var exists: Bool {
    return FileManager.default.fileExists(atPath: caPath)
      && FileManager.default.fileExists(atPath: keyPath)
      && FileManager.default.fileExists(atPath: certPath)
      && FileManager.default.fileExists(atPath: p12Path)
  }

  /// True when the certs were made by an older gen_cert.sh or are about to expire.
  static var needsRenewal: Bool {
    guard exists else { return false }

    let version =
      (try? String(contentsOfFile: versionPath, encoding: .utf8))
      .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
    if version < currentVersion { return true }

    guard let pem = try? String(contentsOfFile: certPath, encoding: .utf8),
      let expiry = notAfter(pem: pem)
    else { return true }

    return expiry.timeIntervalSinceNow < renewalWindow
  }

  static func der(fromPEM pem: String) -> Data? {
    let base64 =
      pem
      .components(separatedBy: .newlines)
      .filter { !$0.hasPrefix("-----") }
      .joined()
    return Data(base64Encoded: base64)
  }

  static func notAfter(pem: String) -> Date? {
    guard let der = der(fromPEM: pem),
      let cert = SecCertificateCreateWithData(nil, der as CFData),
      let values = SecCertificateCopyValues(
        cert, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [String: Any],
      let notAfter = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
      let seconds = notAfter[kSecPropertyKeyValue as String] as? NSNumber
    else { return nil }

    return Date(timeIntervalSinceReferenceDate: seconds.doubleValue)
  }

  /// Runs gen_cert.sh and trusts the new root. Calls back on the main thread with
  /// nil on success, or the script's exit status and output when it failed.
  static func generateCertsIfMissing(_ callback: @escaping (GenerationError?) -> Void) {
    if exists {
      callback(nil)
      return
    }

    let home = URL(fileURLWithPath: NSHomeDirectory())
    let passphrase = Defaults[.userId]!

    DispatchQueue.global(qos: .userInitiated).async {
      let error = generate(in: home, passphrase: passphrase)

      DispatchQueue.main.async {
        if error == nil {
          self.acceptCert()
        }
        callback(error)
      }
    }
  }

  /// Runs gen_cert.sh with `directory` as its working directory, so the certs land in
  /// `directory/Certs`. Returns nil on success. Blocks until the script exits.
  static func generate(in directory: URL, passphrase: String) -> GenerationError? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: scriptPath)
    task.arguments = [Bundle.main.resourcePath!]
    // Explicit: the inherited working directory depends on how the app was launched
    task.currentDirectoryURL = directory
    // Passed via the environment so the passphrase doesn't show up in the process list
    task.environment = ProcessInfo.processInfo.environment.merging(
      ["SPRINKLES_PASS": passphrase], uniquingKeysWith: { $1 })

    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    task.standardInput = FileHandle.nullDevice

    do {
      try task.run()
    } catch {
      log.error("Couldn't start gen_cert.sh: \(error.localizedDescription, privacy: .public)")
      return GenerationError(
        status: nil, output: "Couldn't start gen_cert.sh: \(error.localizedDescription)")
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()

    let output = String(decoding: data, as: UTF8.self)
    let status = task.terminationStatus
    if status != 0 {
      // Error level so it's persisted and shows up in `log show` without --info
      log.error("gen_cert.sh exited \(status): \(output, privacy: .public)")
      return GenerationError(status: status, output: output)
    }
    log.info("gen_cert.sh exited 0: \(output, privacy: .public)")
    return nil
  }

  struct GenerationError: Error, CustomStringConvertible {
    /// nil when the script couldn't be started at all
    let status: Int32?
    let output: String

    /// The exit status and the last lines of output, short enough for an alert.
    var description: String {
      let lines =
        output
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("---") && !$0.hasPrefix("- ") }
        // LibreSSL errors cite the source file of Apple's internal build; drop that noise
        .map { $0.replacingOccurrences(of: "/AppleInternal/\\S*?\\.c:\\d+:", with: "", options: .regularExpression) }
      let tail = lines.suffix(8).joined(separator: "\n")

      var text = status.map { "The certificate script exited with status \($0)." } ?? output
      if status != nil && !tail.isEmpty {
        text += "\n\n" + tail
      }
      return text
    }
  }

  private static let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Sprinkles", category: "certificates")

  static func acceptCert() {
    var err: OSStatus = noErr

    guard let rootCert = rootCert() else { return }

    let dict = NSDictionary.init(
      objects: [kSecClassCertificate, rootCert],
      forKeys: [kSecClass as! NSCopying, kSecValueRef as! NSCopying])

    err = SecItemAdd(dict, nil)
    print(SecCopyErrorMessageString(err, nil) ?? "unknown" as CFString)

    var status: OSStatus = noErr
    // Only trust the root for SSL to localhost, not for everything
    let trustSettings =
      [
        [
          kSecTrustSettingsPolicy: SecPolicyCreateSSL(true, "localhost" as CFString),
          kSecTrustSettingsResult: NSNumber(value: SecTrustSettingsResult.trustRoot.rawValue),
        ]
      ] as CFArray
    status = SecTrustSettingsSetTrustSettings(rootCert, SecTrustSettingsDomain.user, trustSettings)
    print(SecCopyErrorMessageString(status, nil) ?? "unknown" as CFString)
  }

  static func destroy() {
    if let rootCert = rootCert() {
      var status: OSStatus = noErr
      status = SecTrustSettingsRemoveTrustSettings(rootCert, SecTrustSettingsDomain.user)
      print(SecCopyErrorMessageString(status, nil) ?? "unknown" as CFString)

      let query = NSDictionary.init(
        objects: [kSecClassCertificate, [rootCert]],
        forKeys: [kSecClass as! NSCopying, kSecMatchItemList as! NSCopying])
      // kSecValueRef fails with errSecInvalidItemRef for a cert created from file data;
      // kSecMatchItemList matches the keychain copy by content
      status = SecItemDelete(query)
      print(SecCopyErrorMessageString(status, nil) ?? "unknown" as CFString)
    }

    do {
      try FileManager.default.removeItem(at: URL(fileURLWithPath: dir))
    } catch {
      print(error)
    }
  }

  private static func rootCert() -> SecCertificate? {
    guard let data = NSData(contentsOf: URL(fileURLWithPath: caPath)) else { return nil }
    return SecCertificateCreateWithData(nil, data)
  }
}

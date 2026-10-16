import Defaults
import Foundation
import Security

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

  static func generateCertsIfMissing(_ callback: @escaping (Bool) -> Void) {
    if exists {
      callback(true)
    } else {
      let task = Process()
      task.launchPath = SprinklesCertificate.scriptPath
      task.arguments = [Bundle.main.resourcePath!]
      // Passed via the environment so the passphrase doesn't show up in the process list
      task.environment = ProcessInfo.processInfo.environment.merging(
        ["SPRINKLES_PASS": Defaults[.userId]!], uniquingKeysWith: { $1 })

      DispatchQueue.main.async {
        task.launch()
        task.waitUntilExit()

        if task.terminationStatus != 0 {
          callback(false)
          return
        }

        self.acceptCert()

        callback(true)
      }
    }
  }

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
        objects: [kSecClassCertificate, rootCert],
        forKeys: [kSecClass as! NSCopying, kSecValueRef as! NSCopying])
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

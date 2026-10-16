import Defaults
import Foundation
import Telegraph

public enum ServerState: Equatable {
  case stopped
  case booting
  case running
  case failed(String)
}

class Server: ServerDelegate {
  static var instance = Server()

  let headers: HTTPHeaders = [
    .accessControlAllowOrigin: "*",
    .contentType: "text/javascript; charset=utf-8",
  ]
  let jsonHeaders: HTTPHeaders = [
    .accessControlAllowOrigin: "*",
    .contentType: "application/json; charset=utf-8",
  ]
  var server: Telegraph.Server?

  static let onboardingAdvice =
    "Run Onboarding to set up the scripts directory and certificates again."

  var state: ServerState = .stopped {
    didSet { store.dispatch(.serverStateChanged(state)) }
  }

  public func start(_ port: Int = 3133) {
    if state != .stopped { return }

    state = .booting

    guard let caCert = Certificate(derURL: URL(fileURLWithPath: SprinklesCertificate.caPath)) else {
      state = .failed("Couldn't read the Sprinkles certificate. \(Server.onboardingAdvice)")
      return
    }

    guard
      let identity = CertificateIdentity(
        p12URL: URL(fileURLWithPath: SprinklesCertificate.p12Path), passphrase: Defaults[.userId]!)
    else {
      state = .failed(
        "Couldn't read the Sprinkles certificate identity. \(Server.onboardingAdvice)")
      return
    }

    let server = Telegraph.Server(identity: identity, caCertificates: [caCert])
    server.delegate = self

    // v3 manifest
    server.route(.GET, "/v3/domains.json", handleListReq)
    server.route(.GET, "/v3/checksum.json", handleChecksumReq)
    server.route(.GET, "/v3/s/*", handleScriptsReq)
    // v2 manifest/legacy
    server.route(.GET, "/s/*", handleScriptsLegacyReq)
    // meta
    server.route(.GET, "/version.json", handleVersionReq)
    server.serveBundle(.main, "/")

    do {
      try server.start(port: port, interface: "localhost")
    } catch {
      print(error)
      let nsError = error as NSError
      if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EADDRINUSE) {
        state = .failed(
          "Another copy of Sprinkles (or something else) is already listening on port \(port). Quit it and relaunch Sprinkles."
        )
      } else {
        state = .failed(
          "Couldn't listen on localhost:\(port). \(error.localizedDescription) \(Server.onboardingAdvice)"
        )
      }
      return
    }

    state = .running
    self.server = server
  }

  public func stop() {
    server?.stop()
  }

  func serverDidStop(_ server: Telegraph.Server, error: Error?) {
    if let error = error {
      print(error)
      state = .failed(error.localizedDescription)
    } else {
      state = .stopped
    }
  }

  private func handleListReq(request: HTTPRequest) -> HTTPResponse {
    guard let directory = store.state.directory else {
      return HTTPResponse(.internalServerError, content: "[]")
    }

    let fileManager = FileManager.default
    let files = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []

    let jsonData = try? JSONSerialization.data(withJSONObject: Server.domains(in: files))
    let jsonString = String(data: jsonData ?? Data(), encoding: .utf8) ?? "[]"

    return HTTPResponse(.ok, headers: jsonHeaders, content: jsonString)
  }

  private func handleScriptsReq(request: HTTPRequest) -> HTTPResponse {
    guard let domain = Server.parseDomain(request.uri.path) else {
      return HTTPResponse(.unprocessableEntity, content: "console.log('Failed parsing domain')")
    }

    guard let directory = store.state.directory else {
      return HTTPResponse(.internalServerError, content: "console.log('No scripts directory set')")
    }

    let javascript = Server.compileSet(domain, directoryURL: directory)

    return HTTPResponse(HTTPStatus.ok, headers: headers, content: javascript)
  }

  private func handleScriptsLegacyReq(request: HTTPRequest) -> HTTPResponse {
    guard let domain = Server.parseDomain(request.uri.path) else {
      return HTTPResponse(.unprocessableEntity, content: "console.log('Failed parsing domain')")
    }

    guard let directory = store.state.directory else {
      return HTTPResponse(.internalServerError, content: "console.log('No scripts directory set')")
    }

    let global = Server.compileSet("global", directoryURL: directory)
    let javascript = Server.compileSet(domain, directoryURL: directory)
    let combined = global.appending(javascript)

    return HTTPResponse(HTTPStatus.ok, headers: headers, content: combined)
  }

  private func handleVersionReq(request: HTTPRequest) -> HTTPResponse {
    let bundle = Bundle.main
    let version =
      bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    let buildString = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    let build = Int(buildString) ?? 0

    let json: [String: Any] = ["version": version, "build": build]
    let jsonData = try? JSONSerialization.data(withJSONObject: json)
    let jsonString = String(data: jsonData ?? Data(), encoding: .utf8) ?? "{}"

    return HTTPResponse(.ok, headers: jsonHeaders, content: jsonString)
  }

  private func handleChecksumReq(request: HTTPRequest) -> HTTPResponse {
    guard let directory = store.state.directory else {
      return HTTPResponse(.internalServerError, content: "{}")
    }

    let json: [String: Any] = ["checksum": Server.checksum(directoryURL: directory)]
    let jsonData = try? JSONSerialization.data(withJSONObject: json)
    let jsonString = String(data: jsonData ?? Data(), encoding: .utf8) ?? "{}"

    return HTTPResponse(.ok, headers: jsonHeaders, content: jsonString)
  }

  /// Domains that have a script or stylesheet in `files`, excluding the global set and
  /// hidden files (eg. macOS `._` metadata files).
  static func domains(in files: [String]) -> [String] {
    let domains =
      files
      .filter { $0.hasSuffix(".js") || $0.hasSuffix(".css") }
      .filter { !$0.hasPrefix(".") }
      .map { $0.hasSuffix(".js") ? String($0.dropLast(3)) : String($0.dropLast(4)) }
      .filter { $0 != "global" }
    return Array(Set(domains)).sorted()
  }

  /// Extracts "example.com" from paths like "/s/example.com.js". Rejects anything that
  /// could escape the scripts directory.
  static func parseDomain(_ path: String) -> String? {
    guard let range = path.range(of: "/s/"), path.hasSuffix(".js") else { return nil }
    let rest = path[range.upperBound...]
    guard rest.count > 3 else { return nil }
    let domain = String(rest.dropLast(3))

    if domain.contains("/") || domain.contains("\\") || domain.hasPrefix(".") {
      return nil
    }

    return domain
  }

  /// XOR of FNV-1a hashes of each script file's name and contents. Unlike `hashValue` it is
  /// stable across launches, changes when a file is added or renamed, and stays within
  /// JavaScript's safe integer range.
  static func checksum(directoryURL: URL) -> Int {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []

    var checksum: UInt64 = 0
    for file in files where file.hasSuffix(".js") || file.hasSuffix(".css") {
      guard let data = try? Data(contentsOf: directoryURL.appendingPathComponent(file)) else {
        continue
      }
      var bytes = Data(file.utf8)
      bytes.append(0)
      bytes.append(data)
      checksum ^= fnv1a(bytes)
    }

    return Int(checksum & ((1 << 53) - 1))
  }

  private static func fnv1a(_ data: Data) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in data {
      hash ^= UInt64(byte)
      hash = hash &* 0x100_0000_01b3
    }
    return hash
  }

  /// Makes `string` safe to embed in a JS `template literal`, so backslashes
  /// (eg. `content: "\201C"`), backticks and ${ survive as-is.
  static func escapeTemplateLiteral(_ string: String) -> String {
    return
      string
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "`", with: "\\`")
      .replacingOccurrences(of: "${", with: "\\${")
  }

  static func compileSet(_ base: String, directoryURL: URL) -> String {
    let jsURL = directoryURL.appendingPathComponent("\(base).js")
    let cssURL = directoryURL.appendingPathComponent("\(base).css")

    var javascript = tryReading(jsURL)
    let css = tryReading(cssURL)
    if css != "" {
      javascript.append(injectStyleElement(base, css))
    }

    return javascript
  }

  private static func tryReading(_ url: URL) -> String {
    if FileManager.default.fileExists(atPath: url.path) {
      do {
        return try String(contentsOf: url)
      } catch {
        print(error)
      }
    }

    return ""
  }

  private static func injectStyleElement(_ label: String, _ css: String) -> String {
    let fnName = "_SprinklesInjectStyles_\(randomChars())"
    let css = Server.escapeTemplateLiteral(css)

    // Leading newline so a trailing line comment in the user's JS can't swallow the snippet
    return "\n"
      + """
      ;function \(fnName)() {
        console.groupCollapsed("Injecting Sprinkles styles (\(label))");
        console.log(`\(css)`);
        console.groupEnd();

        var d = document;
        var e = d.createElement('style');
        e.dataset.sprinklesInjected = 1;

        e.textContent = `\(css)`;
        d.body.appendChild(e);
      };
      \(fnName)();
      """
  }

  private static func randomChars(length: Int = 8) -> String {
    return String(
      (0..<8).map { _ in
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".randomElement()!
      })
  }
}

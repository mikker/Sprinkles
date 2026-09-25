import Defaults
import Foundation
import Regex
import Telegraph

public enum ServerState {
  case stopped
  case booting
  case running
}

class Server {
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

  var state: ServerState = .stopped {
    didSet { store.dispatch(.serverStateChanged(state)) }
  }

  public func start(_ port: Int = 3133) {
    if state != .stopped { return }

    state = .booting

    guard let caCert = Certificate(derURL: URL(fileURLWithPath: SprinklesCertificate.caPath)) else {
      print("no ca cert")
      stop()
      return
    }

    guard
      let identity = CertificateIdentity(
        p12URL: URL(fileURLWithPath: SprinklesCertificate.p12Path), passphrase: Defaults[.userId]!)
    else {
      print("no p12 cert")
      stop()
      return
    }

    let server = Telegraph.Server(identity: identity, caCertificates: [caCert])

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
      try server.start(port: port)
    } catch {
      print(error)
      stop()
    }

    state = .running
    self.server = server
  }

  public func stop() {
    server?.stop()
  }

  func serverDidStop(_ server: Server, error: Error?) {
    state = .stopped

    if let error = error {
      print(error)
    }
  }

  private func handleListReq(request: HTTPRequest) -> HTTPResponse {
    guard let directory = store.state.directory else {
      return HTTPResponse(.internalServerError, content: "[]")
    }

    let fileManager = FileManager.default
    let files = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
    let domains =
      files
      .filter { $0.hasSuffix(".js") || $0.hasSuffix(".css") }
      .filter { !$0.hasPrefix("global") }
      .map { "(\\.js|\\.css)$".r?.replaceAll(in: $0, with: "") }
    let uniqueDomains = Array(Set(domains.compactMap { $0 })).sorted()

    let jsonData = try? JSONSerialization.data(withJSONObject: uniqueDomains)
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

    let javascript = compileSet(domain, directoryURL: directory)

    return HTTPResponse(HTTPStatus.ok, headers: headers, content: javascript)
  }

  private func handleScriptsLegacyReq(request: HTTPRequest) -> HTTPResponse {
    guard let domain = Server.parseDomain(request.uri.path) else {
      return HTTPResponse(.unprocessableEntity, content: "console.log('Failed parsing domain')")
    }

    guard let directory = store.state.directory else {
      return HTTPResponse(.internalServerError, content: "console.log('No scripts directory set')")
    }

    let global = compileSet("global", directoryURL: directory)
    let javascript = compileSet(domain, directoryURL: directory)
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

  private func compileSet(_ base: String, directoryURL: URL) -> String {
    let jsURL = directoryURL.appendingPathComponent("\(base).js")
    let cssURL = directoryURL.appendingPathComponent("\(base).css")

    var javascript = tryReading(jsURL)
    let css = tryReading(cssURL)
    if css != "" {
      javascript.append(injectStyleElement(base, css))
    }

    return javascript
  }

  private func tryReading(_ url: URL) -> String {
    if FileManager.default.fileExists(atPath: url.path) {
      do {
        return try String(contentsOf: url)
      } catch {
        print(error)
      }
    }

    return ""
  }

  private func injectStyleElement(_ label: String, _ css: String) -> String {
    let fnName = "_SprinklesInjectStyles_\(randomChars())"
    let css = Server.escapeTemplateLiteral(css)

    return """
      ;function \(fnName)() {
        console.groupCollapsed("Injecting Sprinkles styles (\(label))");
        console.log(`\(css)`);
        console.groupEnd();

        var d = document;
        var e = d.createElement('style');
        e.dataset.sprinklesInjected = 1;

        var content = `\(css)`;
        if (window.trustedTypes && trustedTypes.createPolicy) {
          const escapeHTMLPolicy = trustedTypes.createPolicy("myEscapePolicy", {
            createHTML: (content) => content.replace(/\\</g, "&lt;"),
          });

          content = escapeHTMLPolicy.createHTML(content);
        }

        e.innerHTML = content;
        d.body.appendChild(e);
      };
      \(fnName)();
      """
  }

  private func randomChars(length: Int = 8) -> String {
    return String(
      (0..<8).map { _ in
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".randomElement()!
      })
  }
}

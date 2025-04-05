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
    guard let domain = "/s\\/(.*)\\.js".r?.findFirst(in: request.uri.path)?.group(at: 1)
    else {
      return HTTPResponse(.unprocessableEntity, content: "console.log('Failed parsing domain')")
    }

    guard let directory = store.state.directory else {
      return HTTPResponse(.internalServerError, content: "console.log('No scripts directory set')")
    }

    let javascript = compileSet(domain, directoryURL: directory)

    return HTTPResponse(HTTPStatus.ok, headers: headers, content: javascript)
  }

  private func handleScriptsLegacyReq(request: HTTPRequest) -> HTTPResponse {
    guard let domain = "/s\\/(.*)\\.js".r?.findFirst(in: request.uri.path)?.group(at: 1)
    else {
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

    let fileManager = FileManager.default
    let files = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
    let scriptFiles = files.filter { $0.hasSuffix(".js") || $0.hasSuffix(".css") }

    var checksum = 0
    for file in scriptFiles {
      let fileURL = directory.appendingPathComponent(file)
      if let data = try? Data(contentsOf: fileURL) {
        checksum ^= data.hashValue
      }
    }

    let json: [String: Any] = ["checksum": checksum]
    let jsonData = try? JSONSerialization.data(withJSONObject: json)
    let jsonString = String(data: jsonData ?? Data(), encoding: .utf8) ?? "{}"

    return HTTPResponse(.ok, headers: jsonHeaders, content: jsonString)
  }

  private func compileSet(_ base: String, directoryURL: URL) -> String {
    let jsURL = directoryURL.appendingPathComponent("\(base).js")
    let cssURL = directoryURL.appendingPathComponent("\(base).css")

    var javascript = tryReading(jsURL)
    let css = tryReading(cssURL)
    if css != "" {
      javascript.append(injectStyleElement(css))
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

  private func injectStyleElement(_ css: String) -> String {
    return """
      function _SprinklesInjectStyles() {
        var d = document;
        var e = d.createElement('style');
        e.dataset.sprinklesInjected = 1;
        e.innerHTML = `\(css)`;
        d.body.appendChild(e);
      };
      _SprinklesInjectStyles();
      """
  }
}

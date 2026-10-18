//
//  SprinklesTests.swift
//  SprinklesTests
//
//  Created by Mikkel Malmberg on 16/01/2019.
//  Copyright © 2019 Brainbow. All rights reserved.
//

import XCTest

@testable import Sprinkles

class SprinklesTests: XCTestCase {

  override func setUp() {
    // Put setup code here. This method is called before the invocation of each test method in the class.
  }

  override func tearDown() {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
  }

  func testParseDomain() {
    XCTAssertEqual(Server.parseDomain("/v3/s/example.com.js"), "example.com")
    XCTAssertEqual(Server.parseDomain("/s/sub.example.com.js"), "sub.example.com")
    XCTAssertNil(Server.parseDomain("/v3/s/.js"))
    XCTAssertNil(Server.parseDomain("/v3/s/example.com.css"))
    XCTAssertNil(Server.parseDomain("/v3/s/../../secret.js"))
    XCTAssertNil(Server.parseDomain("/v3/s/..\\secret.js"))
  }

  func testEscapeTemplateLiteral() {
    XCTAssertEqual(
      Server.escapeTemplateLiteral("p::before { content: \"\\201C\"; } /* `${x}` */"),
      "p::before { content: \"\\\\201C\"; } /* \\`\\${x}\\` */")
  }

  func testChecksum() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    try "a".write(to: dir.appendingPathComponent("global.js"), atomically: true, encoding: .utf8)
    let first = Server.checksum(directoryURL: dir)
    XCTAssertEqual(first, Server.checksum(directoryURL: dir))
    XCTAssertLessThan(first, 1 << 53)

    try "".write(
      to: dir.appendingPathComponent("example.com.css"), atomically: true, encoding: .utf8)
    let second = Server.checksum(directoryURL: dir)
    XCTAssertNotEqual(first, second)

    try "b".write(to: dir.appendingPathComponent("global.js"), atomically: true, encoding: .utf8)
    XCTAssertNotEqual(second, Server.checksum(directoryURL: dir))
  }

  func testDomainsExcludesOnlyGlobalAndHiddenFiles() {
    let files = [
      "global.js", "global.css", "globalnews.ca.css", "example.com.js", "example.com.css",
      "._example.com.js", ".hidden.js", "notes.txt",
    ]
    XCTAssertEqual(Server.domains(in: files), ["example.com", "globalnews.ca"])
  }

  func testCompileSetSurvivesTrailingLineComment() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    try "console.log(1)\n// comment".write(
      to: dir.appendingPathComponent("global.js"), atomically: true, encoding: .utf8)
    try "body { color: red; }".write(
      to: dir.appendingPathComponent("global.css"), atomically: true, encoding: .utf8)

    let output = Server.compileSet("global", directoryURL: dir)
    XCTAssertTrue(output.contains("// comment\n;function"))
    for line in output.components(separatedBy: "\n") where line.contains(";function") {
      XCTAssertFalse(line.hasPrefix("//"))
    }
  }

  func testAllowedOrigin() {
    for origin in [
      "safari-web-extension://ABC-123", "chrome-extension://abcdef", "moz-extension://1234-5678",
    ] {
      XCTAssertEqual(Server.allowedOrigin(origin), origin)
    }
    XCTAssertNil(Server.allowedOrigin(nil))
    XCTAssertNil(Server.allowedOrigin(""))
    XCTAssertNil(Server.allowedOrigin("null"))
    XCTAssertNil(Server.allowedOrigin("https://example.com"))
    XCTAssertNil(Server.allowedOrigin("https://chrome-extension.example.com"))
    XCTAssertNil(Server.allowedOrigin("http://localhost:3133"))
  }

  func testExampleFilesEndWithNewline() {
    XCTAssertTrue(ExampleFiles.globalJS.hasSuffix("\n"))
    XCTAssertTrue(ExampleFiles.globalCSS.hasSuffix("\n"))
  }

  func testCertificateNotAfter() {
    // openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    //   -subj /CN=localhost -not_before 20260101000000Z -not_after 20300102030405Z
    let pem = """
      -----BEGIN CERTIFICATE-----
      MIIBWzCCAQKgAwIBAgIUCju7yWgW1jyaBkWDDSbuGN4+P2cwCgYIKoZIzj0EAwIw
      FDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI2MDEwMTAwMDAwMFoXDTMwMDEwMjAz
      MDQwNVowFDESMBAGA1UEAwwJbG9jYWxob3N0MFkwEwYHKoZIzj0CAQYIKoZIzj0D
      AQcDQgAEHWjCqTnbGn2pD876lGYfyRmd6psjAkPJTTyjb2DtoSEj2y+xxy/9IXf9
      EmCDFX9qYnBTSFw5oyWtwSo9+d314qMyMDAwHQYDVR0OBBYEFJPtoKP/sOzT1EpH
      0olWML5LWrV8MA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDRwAwRAIgUo0o
      JgL5KP51O2EndBWmmP+b63DdUoz3v6B1GeguRP0CIBV6brwYrMxIy2yiDJ8tH10T
      UtqHvKK/g6TthdSF5aNS
      -----END CERTIFICATE-----

      """

    let der = SprinklesCertificate.der(fromPEM: pem)
    XCTAssertEqual(der?.count, 351)
    XCTAssertEqual(der?.first, 0x30)

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let expected = calendar.date(
      from: DateComponents(year: 2030, month: 1, day: 2, hour: 3, minute: 4, second: 5))
    XCTAssertEqual(SprinklesCertificate.notAfter(pem: pem), expected)

    XCTAssertNil(SprinklesCertificate.notAfter(pem: "not a certificate"))
  }

  func testGenerateWritesCertsIntoDirectory() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("sprinkles-certs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    XCTAssertNil(SprinklesCertificate.generate(in: dir, passphrase: "secret"))

    let certs = dir.appendingPathComponent("Certs")
    for name in ["ca.der", "key.pem", "cert.pem", "identity.p12", "version"] {
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: certs.appendingPathComponent(name).path),
        "\(name) missing")
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: certs.appendingPathComponent("ca_key.pem").path),
      "root CA key should be removed after signing")
  }

  func testGenerateReportsScriptOutputOnFailure() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("sprinkles-certs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let error = try XCTUnwrap(SprinklesCertificate.generate(in: dir, passphrase: ""))
    XCTAssertEqual(error.status, 1)
    XCTAssertTrue(error.output.contains("SPRINKLES_PASS is not set"))
    XCTAssertTrue(error.description.contains("exited with status 1"))
    XCTAssertTrue(error.description.contains("SPRINKLES_PASS is not set"))
  }

  func testPerformanceExample() {
    // This is an example of a performance test case.
    self.measure {
      // Put the code you want to measure the time of here.
    }
  }

}

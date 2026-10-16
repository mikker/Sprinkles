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

  func testExampleFilesEndWithNewline() {
    XCTAssertTrue(ExampleFiles.globalJS.hasSuffix("\n"))
    XCTAssertTrue(ExampleFiles.globalCSS.hasSuffix("\n"))
  }

  func testPerformanceExample() {
    // This is an example of a performance test case.
    self.measure {
      // Put the code you want to measure the time of here.
    }
  }

}

import Foundation

class ExampleFiles {
  static let globalCSS =
    """
    /* This is Sprinkles' global.css.
     *
     * The styles you add here will be added to every page you visit.
     *
     * To add styles specific to a single domain, create files in this directory, named
     * after the (full) domain, eg. "twitter.com.css" or "subdomain.example.com.css".
     *
     * For example, uncomment the line below to get an extra creamy web experience: */

     /* body { background-color: papayawhip; } */

    """

  static let globalJS =
    """
    // This is Sprinkles' global.js.
    //
    // The JavaScript code you add here will be run on every page you visit.
    //
    // To add scripts specific to a single domain, create files in this directory, name
    // after the domain, eg. "twitter.com.js" or "subdomain.example.com.js".
    //
    // For example, uncomment the lines below to change every image on the web to random new one:

    // for (const elm of document.querySelectorAll("img")) {
    //   elm.src = `//picsum.photos/${elm.width}`
    // }

    """

  static func copyTo(directoryAtPath path: String) {
    writeIfNotExists(path: path + "/global.css", content: globalCSS)
    writeIfNotExists(path: path + "/global.js", content: globalJS)
  }

  private static func writeIfNotExists(path: String, content: String) {
    if !FileManager.default.fileExists(atPath: path) {
      print("Writing default \(path)")
      FileManager.default.createFile(
        atPath: path, contents: content.data(using: .utf8), attributes: nil)
    }
  }
}

import Cocoa

public class Bookmark {
  typealias Permissions = [URL: Data]

  public static var url: URL? {
    get { return instance.url }
    set(url) { instance.url = url }
  }

  private static let instance = Bookmark()

  private var url: URL? {
    get {
      readFromDisk()
    }

    set(maybeUrl) {
      guard let url = maybeUrl else { return removeBookmark() }
      saveToDisk(url)
    }
  }

  private func fileURL() -> URL {
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] as URL
    return url.appendingPathComponent("Bookmark.dict")
  }

  private func bookmarkExists() -> Bool {
    return FileManager.default.fileExists(atPath: fileURL().path)
  }

  private func readFromDisk() -> URL? {
    guard bookmarkExists() else { return nil }
    guard let dir = readBookmark() else { return nil }
    return dir
  }

  private func readBookmark() -> URL? {
    var isStale = ObjCBool(false)
    let restored: URL?

    do {
      let fileData = try Data(contentsOf: fileURL())
      let unarchiver = try NSKeyedUnarchiver(forReadingFrom: fileData)
      unarchiver.requiresSecureCoding = false
      NSKeyedUnarchiver.setClass(NSURL.self, forClassName: "NSURL")
      NSKeyedUnarchiver.setClass(NSData.self, forClassName: "NSData")

      guard
        let permissions = unarchiver.decodeObject(
          of: [NSDictionary.self, NSURL.self, NSData.self], forKey: NSKeyedArchiveRootObjectKey)
          as? Permissions
      else { return nil }
      guard let (_, data) = permissions.first else { return nil }
      restored =
        try NSURL(
          resolvingBookmarkData: data,
          options: .withSecurityScope,
          relativeTo: nil,
          bookmarkDataIsStale: &isStale) as URL
    } catch {
      print(error)
      return nil
    }

    guard let restored = restored else { return nil }
    guard restored.startAccessingSecurityScopedResource() else { return nil }

    if isStale.boolValue {
      saveToDisk(restored)
    }

    return restored
  }

  private func saveToDisk(_ url: URL) {
    var url = url
    let bookmarkData: Data

    do {
      url.resolveSymlinksInPath()
      bookmarkData = try url.bookmarkData(
        options: .withSecurityScope,
        includingResourceValuesForKeys: nil, relativeTo: nil)
    } catch {
      print(error)
      return
    }

    let permission = [url: bookmarkData]

    do {
      let archiver = NSKeyedArchiver(requiringSecureCoding: false)
      archiver.encode(permission, forKey: NSKeyedArchiveRootObjectKey)
      let data = archiver.encodedData
      try data.write(to: fileURL())
    } catch {
      print(error)
      return
    }
  }

  private func removeBookmark() {
    guard bookmarkExists() else { return }
    do {
      try FileManager.default.removeItem(at: fileURL())
    } catch {}
  }
}

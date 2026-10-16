import Cocoa

class StatusItem: NSObject {
  var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

  let serverFailedItem = NSMenuItem(title: "Server not running", action: nil, keyEquivalent: "")
  let serverFailedSeparator = NSMenuItem.separator()
  var unsubscribe: UnsubscribeFn?

  override func awakeFromNib() {
    statusItem.button?.image = NSImage(named: NSImage.Name("ToolbarItemIcon"))
    statusItem.menu = buildMenu()

    unsubscribe = store.subscribe { state in
      let notRunning = state.serverState != .running && state.serverState != .booting
      self.serverFailedItem.isHidden = !notRunning
      self.serverFailedSeparator.isHidden = !notRunning
    }
  }

  deinit {
    unsubscribe?()
  }

  private func buildMenu() -> NSMenu {
    let menu = NSMenu()

    serverFailedItem.isEnabled = false
    menu.addItem(serverFailedItem)
    menu.addItem(serverFailedSeparator)

    let preferencesItem = NSMenuItem(
      title: "Preferences…", action: #selector(showPreferences), keyEquivalent: ",")
    preferencesItem.target = self
    menu.addItem(preferencesItem)

    let onboardingItem = NSMenuItem(
      title: "Onboarding…", action: #selector(showOnboarding), keyEquivalent: "")
    onboardingItem.target = self
    menu.addItem(onboardingItem)

    let directoryItem = NSMenuItem(
      title: "Open directory…", action: #selector(openDirectory), keyEquivalent: "o")
    directoryItem.target = self
    menu.addItem(directoryItem)

    menu.addItem(NSMenuItem.separator())
    menu.addItem(
      NSMenuItem(
        title: "Quit Sprinkles", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    )

    return menu
  }

  @objc func openDirectory() {
    if let directory = store.state.directory {
      NSWorkspace.shared.open(directory)
    } else {
      showPreferences()
    }
  }

  @objc func showPreferences() {
    guard let delegate = NSApplication.shared.delegate as? AppDelegate else { return }
    delegate.showPreferences()
  }

  @objc func showOnboarding() {
    guard let delegate = NSApplication.shared.delegate as? AppDelegate else { return }
    delegate.showOnboarding()
  }
}

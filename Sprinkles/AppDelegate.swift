import Cocoa
import Defaults
import Settings

extension Settings.PaneIdentifier {
  static let general = Self("general")
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
  @IBOutlet var onboarding: OnboardingController!

  var hasShownServerFailure = false

  lazy var preferences = SettingsWindowController(
    panes: [GeneralPreferencesController()], style: .segmentedControl)

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }

    if Defaults[.userId] == nil {
      Defaults[.userId] = UUID().uuidString
    }

    _ = store.subscribe { state in
      if state.hasCert && state.directory != nil {
        Server.instance.start(3133)
      }

      if case .failed(let reason) = state.serverState, !self.hasShownServerFailure {
        self.hasShownServerFailure = true
        self.showServerFailure(reason)
      }
    }

    if Defaults[.showPreferencesOnLaunch] {
      showPreferences()
    }

    if !Defaults[.hasOnboarded] {
      showOnboarding()
    } else if !store.state.hasCert || store.state.directory == nil {
      hasShownServerFailure = true
      showServerFailure(
        "The scripts directory or the certificates are missing. \(Server.onboardingAdvice)")
    }
  }

  func applicationWillTerminate(_ aNotification: Notification) {
    Server.instance.stop()
  }

  func showPreferences() {
    preferences.show()
  }

  func showServerFailure(_ reason: String) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Sprinkles server not running"
    alert.informativeText = reason
    alert.addButton(withTitle: "Open Onboarding…")
    alert.addButton(withTitle: "Dismiss")

    NSApp.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertFirstButtonReturn {
      showOnboarding()
    }
  }

  func showOnboarding() {
    Defaults[.hasOnboarded] = false
    self.onboarding.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}

extension NSApplication {
  func relaunch(afterDelay seconds: TimeInterval = 0.5) -> Never {
    let task = Process()
    task.launchPath = "/bin/sh"
    task.arguments = ["-c", "sleep \(seconds); open \"\(Bundle.main.bundlePath)\""]
    task.launch()

    self.terminate(nil)
    exit(0)
  }
}

import Cocoa
import Defaults
import LaunchAtLogin
import SafariServices

class OnboardingController: NSWindowController {
  enum Page {
    case page1, page2, page3
  }

  @IBOutlet var step1: OnboardingStep1View!
  @IBOutlet var step2: OnboardingStep2View!
  @IBOutlet var step3: OnboardingStep3View!
  @IBOutlet weak var contentBox: NSBox!

  var currentPage: Page = .page1

  init() {
    super.init(window: nil)

    Bundle.main.loadNibNamed(NSNib.Name("Onboarding"), owner: self, topLevelObjects: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func awakeFromNib() {
    goToPage(currentPage)
  }

  func goToPage(_ page: Page) {
    currentStep().removeFromSuperview()

    currentPage = page

    let step = currentStep()
    contentBox.addSubview(step)
  }

  func currentStep() -> NSView {
    switch currentPage {
    case .page1: return step1
    case .page2: return step2
    case .page3: return step3
    }
  }
}

class OnboardingStep1View: NSView {
  @IBOutlet weak var controller: OnboardingController!
  @IBOutlet weak var directoryPathControl: NSPathControl!
  @IBOutlet weak var chooseLocationButton: NSButton!
  @IBOutlet weak var nextButton: NSButton!

  var unsubscribe: UnsubscribeFn?

  override func awakeFromNib() {
    self.window?.makeFirstResponder(chooseLocationButton)

    unsubscribe = store.subscribe { state in
      self.nextButton.isEnabled = state.directory != nil
      guard state.directory != nil else { return }
      self.directoryPathControl.url = state.directory
    }
  }

  deinit {
    unsubscribe?()
  }

  @IBAction func didPressPick(_ sender: Any) {
    OpenPanel.pick { result in
      guard let url = result else { return }

      Bookmark.url = url
      store.dispatch(.setDirectory(url))
    }
  }

  @IBAction func didPressNext(_ sender: Any) {
    guard let dir = store.state.directory else { return }
    ExampleFiles.copyTo(directoryAtPath: dir.path)
    controller.goToPage(.page2)
  }
}

class OnboardingStep2View: NSView {
  @IBOutlet weak var controller: OnboardingController!
  @IBOutlet weak var generateButton: NSButton!
  @IBOutlet weak var nextButton: NSButton!
  @IBOutlet weak var checkmark: NSTextField!

  var unsubscribe: UnsubscribeFn?

  override func awakeFromNib() {
    self.window?.makeFirstResponder(generateButton)

    unsubscribe = store.subscribe { state in
      self.nextButton.isEnabled = state.hasCert

      self.generateButton.isEnabled = !state.hasCert
      self.checkmark.isHidden = !state.hasCert

      if state.hasCert {
        self.window?.makeFirstResponder(self.nextButton)
      }
    }
  }

  deinit {
    unsubscribe?()
  }

  @IBAction func didPressGenerate(_ sender: Any) {
    generateButton.isEnabled = false

    SprinklesCertificate.generateCertsIfMissing { error in
      store.dispatch(.hasCert(error == nil))

      guard let error = error, let window = self.window else { return }
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "Couldn't generate certificates"
      alert.informativeText = error.description
      alert.beginSheetModal(for: window)
    }
  }

  @IBAction func didPressNext(_ sender: Any) {
    controller.goToPage(.page3)
  }
}

class OnboardingStep3View: NSView {
  @IBOutlet weak var controller: OnboardingController!

  @IBOutlet weak var safariButton: NSButton!
  @IBOutlet weak var firefoxButton: NSButton!
  @IBOutlet weak var chromeButton: NSButton!
  @IBOutlet weak var doneButton: NSButton!
  @IBOutlet weak var launchAtLoginCheckbox: NSButton!

  @IBAction func safariPressed(_ sender: Any) {
    ExtensionLinks.safari()
  }

  @IBAction func firefoxPressed(_ sender: Any) {
    ExtensionLinks.firefox()
  }

  @IBAction func googleChromePressed(_ sender: Any) {
    ExtensionLinks.chrome()
  }

  @IBAction func closePressed(_ sender: Any) {
    Defaults[.hasOnboarded] = true
    store.dispatch(.setIsOnboarding(false))

    controller.close()

    if let delegate = NSApplication.shared.delegate as? AppDelegate {
      delegate.preferences.show()
    }
  }
}

set dotenv-load := true

project := "Sprinkles.xcodeproj"
scheme := "Sprinkles"
derived_data := "build/dd"
app := justfile_directory() + "/" + derived_data + "/Build/Products/Debug/Sprinkles.app"

# Build the local Debug app.
default: build

# List available Xcode schemes and targets.
list:
  xcodebuild -list -project {{project}}

# Build the Debug app with the project's development signing.
build:
  scripts/agent-build.sh build -project {{project}} -scheme {{scheme}} -configuration Debug -destination 'platform=macOS'

# Run the unit tests.
test:
  scripts/agent-build.sh test -project {{project}} -scheme {{scheme}} -destination 'platform=macOS'

# Build and test before considering a change ready.
check: build test

# Rebuild, quit the running copy, and run the Debug app attached so logs stream here.
run: build kill
  '{{app}}/Contents/MacOS/Sprinkles'

# Quit the running Sprinkles (Debug or installed).
kill:
  pkill -x Sprinkles || true

# Remove build products and logs.
clean:
  rm -rf build dist

# Open the project in Xcode.
open:
  open '{{project}}'

# Show the last 80 lines of the newest build log.
log-tail:
  #!/bin/zsh
  logs=(build/xcodebuild/*.log(Nom))
  if (( ${#logs} )); then
    tail -n 80 "$logs[1]"
  else
    print 'No build logs yet.'
  fi

# Set the build number to the commit count plus 9 (never lower than the current one).
bump:
  scripts/bump.sh

# Zip the Chrome and Firefox extensions into dist/.
extensions:
  scripts/release-ext.sh

# Archive the app for the App Store and export dist/Sprinkles.pkg, without uploading.
package version="":
  scripts/package-release.sh {{quote(version)}}

# Upload dist/Sprinkles.pkg to App Store Connect.
upload:
  scripts/package-release.sh --upload

# One App Store Connect step by hand: builds | prepare X.Y | submit X.Y | status.
[positional-arguments]
appstore *args:
  python3 scripts/appstore.py "$@"

# Prepare, test, package, upload, tag, publish on GitHub and submit for review, from a clean, pushed main.
release version="":
  scripts/release.sh {{quote(version)}}

#!/bin/bash
set -e

# Build number is the commit count + 9, but never lower than the current one + 1
# (the commit count can go down after a squash or rebase)
COMMITS=$(git rev-list "$(git rev-parse --abbrev-ref HEAD)" | wc -l | awk '{ print $1 }')
CURRENT=$(agvtool what-version -terse)
BUILD="$((COMMITS + 9))"
if [ "$BUILD" -le "$CURRENT" ]; then
  BUILD="$((CURRENT + 1))"
fi

echo "${BUILD}"

# Set it in the project only. `agvtool new-version -all` would also replace the
# $(CURRENT_PROJECT_VERSION) placeholders in the Info.plists with literal numbers.
sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = ${BUILD};/" \
  Sprinkles.xcodeproj/project.pbxproj

echo "Resolving package dependencies"
xcodebuild -resolvePackageDependencies

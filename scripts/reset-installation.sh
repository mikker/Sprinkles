#!/bin/bash -x
osascript -e 'tell application "Sprinkles" to quit'
rm -rf ~/Library/Containers/com.brnbw.Sprinkles*
mdfind -0 "kMDItemContentType == 'com.apple.application-bundle'" | grep -z '/Sprinkles\.app$' | xargs -0 rm -rf


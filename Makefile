APP = build/Lid Glow.app
APP_TARGET = build/Lid\ Glow.app
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' src/Info.plist)
ZIP = build/Lid-Glow-$(VERSION).zip

.PHONY: all zip
all: $(APP_TARGET)/Contents/MacOS/LidGlow

$(APP_TARGET)/Contents/MacOS/LidGlow: src/LidGlow.m src/Info.plist assets/LidGlow.icns LICENSE Makefile
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	xcrun clang -Wall -Wextra -Wno-unused-parameter -fobjc-arc -O2 -arch arm64 -mmacosx-version-min=27.2 src/LidGlow.m -framework AppKit -framework CoreGraphics -o "$@"
	cp src/Info.plist "$(APP)/Contents/Info.plist"
	cp assets/LidGlow.icns LICENSE "$(APP)/Contents/Resources/"
	codesign --force --sign - "$(APP)"

zip: $(ZIP)

$(ZIP): $(APP_TARGET)/Contents/MacOS/LidGlow
	ditto -c -k --sequesterRsrc --keepParent "$(APP)" "$@"

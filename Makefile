APP     = AutoEnclave
BUNDLE  = build/$(APP).app
BIN     = .build/release/$(APP)

.PHONY: all build bundle run install dmg clean

all: bundle

build:
	swift build -c release

bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	codesign --force --sign - $(BUNDLE)

run: bundle
	open $(BUNDLE)

# Copy into /Applications so "launch at login" has a stable path.
install: bundle
	pkill -x $(APP) || true
	rm -rf /Applications/$(APP).app
	cp -R $(BUNDLE) /Applications/
	open /Applications/$(APP).app

# Drag-to-install disk image: build/AutoEnclave.dmg with the app and an Applications shortcut.
dmg: bundle
	rm -rf build/dmg build/$(APP).dmg
	mkdir -p build/dmg
	cp -R $(BUNDLE) build/dmg/
	ln -s /Applications build/dmg/Applications
	hdiutil create -quiet -volname $(APP) -srcfolder build/dmg -ov -format UDZO build/$(APP).dmg
	rm -rf build/dmg
	@echo "Created build/$(APP).dmg"

clean:
	rm -rf .build build

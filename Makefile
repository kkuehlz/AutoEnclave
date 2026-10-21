APP     = AutoEnclave
BUNDLE  = build/$(APP).app
BIN     = .build/release/$(APP)

.PHONY: all build bundle run install clean test

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

test:
	swift run -c release sshconfig-checks

clean:
	rm -rf .build build

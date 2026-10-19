APP := build/Agent Float.app

.PHONY: build test clean bundle run

build:
	swift build -c release

test:
	swift test

bundle: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS"
	cp "$$(swift build -c release --show-bin-path)/AgentFloat" "$(APP)/Contents/MacOS/AgentFloat"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	codesign --force --sign - "$(APP)"

run: bundle
	open "$(APP)"

clean:
	swift package clean
	rm -rf .build build

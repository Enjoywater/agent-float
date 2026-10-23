APP := build/Agent Float.app
INSTALL_DIR ?= /Applications
INSTALLED := $(INSTALL_DIR)/Agent Float.app
BUNDLE_ID := dev.enjoywater.agent-float
# 같은 인증서로 서명해야 다시 빌드해도 손쉬운 사용·자동화 권한이 유지된다 (scripts/create-signing-identity.sh)
SIGN_IDENTITY ?= Agent Float Local Signing

.PHONY: build test clean bundle run install

build:
	swift build -c release

test:
	swift test

bundle: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$$(swift build -c release --show-bin-path)/AgentFloat" "$(APP)/Contents/MacOS/AgentFloat"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	cp Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$(APP)/Contents/Resources/"
	@if security find-identity -v -p codesigning | grep -F -q '"$(SIGN_IDENTITY)"'; then \
		echo codesign --force --sign "$(SIGN_IDENTITY)" "$(APP)"; \
		codesign --force --sign "$(SIGN_IDENTITY)" "$(APP)"; \
	else \
		echo "경고: $(SIGN_IDENTITY) 인증서가 없어 ad-hoc 서명합니다. 다시 빌드하면 손쉬운 사용·자동화 권한이 풀립니다 (scripts/create-signing-identity.sh)" >&2; \
		codesign --force --sign - "$(APP)"; \
	fi

run: bundle
	open "$(APP)"

# 빌드가 실패하면 쓰던 앱이 그대로 남도록 먼저 조립한다. 위치 저장(R28)이 끝나도록 강제 종료 대신 quit 을 보낸다
install: bundle
	@if pgrep -x AgentFloat >/dev/null; then \
		osascript -e 'tell application id "$(BUNDLE_ID)" to quit'; \
		for i in $$(seq 50); do pgrep -x AgentFloat >/dev/null || break; sleep 0.2; done; \
		if pgrep -x AgentFloat >/dev/null; then echo "Agent Float 이 10초 안에 종료되지 않음" >&2; exit 1; fi; \
	fi
	rm -rf "$(INSTALLED)"
	ditto "$(APP)" "$(INSTALLED)"
	open "$(INSTALLED)"

clean:
	swift package clean
	rm -rf .build build

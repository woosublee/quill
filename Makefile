APP_NAME ?= Quill
BUNDLE_ID ?= com.woosublee.quill
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CODESIGN_IDENTITY ?= Quill
GOOGLE_CALENDAR_OAUTH_CLIENT_ID ?=
GOOGLE_CALENDAR_OAUTH_CLIENT_SECRET ?=
-include $(HOME)/.config/quill/oauth.env
-include .env
CONTENTS = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS)/MacOS
BUILD_SETTINGS = $(BUILD_DIR)/.build-settings
empty :=
space := $(empty) $(empty)
APP_EXECUTABLE = $(MACOS_DIR)/$(APP_NAME)
APP_EXECUTABLE_TARGET := $(subst $(space),\ ,$(APP_EXECUTABLE))

SOURCES = $(shell find Sources -name '*.swift' -type f | LC_ALL=C sort)
RESOURCES = $(CONTENTS)/Resources
ARCH ?= $(shell uname -m)

# Pick the icon source based on which bundle we are building. Dev builds get
# a distinct hammer-on-waveform icon so a developer's dock shows at a glance
# which Quill build they are running when both are installed side by side.
ifeq ($(APP_NAME),Quill Dev)
ICON_SOURCE = Resources/AppIcon-Dev-Source.png
ICON_ICNS = Resources/AppIcon-Dev.icns
else
ICON_SOURCE = Resources/AppIcon-Source.png
ICON_ICNS = Resources/AppIcon.icns
endif

# Usage: make install CODESIGN_IDENTITY="Apple Development: you@example.com (TEAMID)"
.PHONY: all clean run icon dmg codesign-dmg notarize install reset-permissions install-and-run test FORCE

all: $(APP_EXECUTABLE_TARGET)

$(BUILD_SETTINGS): FORCE
	@mkdir -p "$(BUILD_DIR)"
	@printf '%s\n%s\n%s\n%s\n' "$(APP_NAME)" "$(BUNDLE_ID)" "$(GOOGLE_CALENDAR_OAUTH_CLIENT_ID)" "$(GOOGLE_CALENDAR_OAUTH_CLIENT_SECRET)" > "$@.tmp"
	@if [ ! -f "$@" ] || ! cmp -s "$@.tmp" "$@"; then mv "$@.tmp" "$@"; else rm "$@.tmp"; fi

$(APP_EXECUTABLE_TARGET): $(SOURCES) Info.plist $(ICON_ICNS) $(BUILD_SETTINGS)
	@mkdir -p "$(MACOS_DIR)" "$(RESOURCES)"
ifeq ($(ARCH),universal)
	swiftc \
		-parse-as-library \
		-o "$(MACOS_DIR)/$(APP_NAME)-arm64" \
		-sdk $(shell xcrun --show-sdk-path) \
		-target arm64-apple-macosx13.0 \
		$(SOURCES)
	swiftc \
		-parse-as-library \
		-o "$(MACOS_DIR)/$(APP_NAME)-x86_64" \
		-sdk $(shell xcrun --show-sdk-path) \
		-target x86_64-apple-macosx13.0 \
		$(SOURCES)
	lipo -create -output "$(MACOS_DIR)/$(APP_NAME)" \
		"$(MACOS_DIR)/$(APP_NAME)-arm64" \
		"$(MACOS_DIR)/$(APP_NAME)-x86_64"
	@rm "$(MACOS_DIR)/$(APP_NAME)-arm64" "$(MACOS_DIR)/$(APP_NAME)-x86_64"
else
	swiftc \
		-parse-as-library \
		-o "$(MACOS_DIR)/$(APP_NAME)" \
		-sdk $(shell xcrun --show-sdk-path) \
		-target $(ARCH)-apple-macosx13.0 \
		$(SOURCES)
endif
	@cp Info.plist "$(CONTENTS)/"
	@plutil -replace CFBundleName -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleDisplayName -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleExecutable -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleIdentifier -string "$(BUNDLE_ID)" "$(CONTENTS)/Info.plist"
	@plutil -replace GoogleCalendarOAuthClientID -string "$(GOOGLE_CALENDAR_OAUTH_CLIENT_ID)" "$(CONTENTS)/Info.plist"
	@plutil -replace GoogleCalendarOAuthClientSecret -string "$(GOOGLE_CALENDAR_OAUTH_CLIENT_SECRET)" "$(CONTENTS)/Info.plist"
	@cp $(ICON_ICNS) "$(RESOURCES)/"
	@xattr -cr "$(APP_BUNDLE)"
	@rm -rf "$(BUILD_DIR)/codesign-staging"
	@mkdir -p "$(BUILD_DIR)/codesign-staging"
	@ditto --norsrc "$(APP_BUNDLE)" "$(BUILD_DIR)/codesign-staging/$(APP_NAME).app"
	@codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" --entitlements Quill.entitlements "$(BUILD_DIR)/codesign-staging/$(APP_NAME).app"
	@rm -rf "$(APP_BUNDLE)"
	@ditto "$(BUILD_DIR)/codesign-staging/$(APP_NAME).app" "$(APP_BUNDLE)"
	@rm -rf "$(BUILD_DIR)/codesign-staging"
	@echo "Built $(APP_BUNDLE)"

icon: $(ICON_ICNS)

$(ICON_ICNS): $(ICON_SOURCE)
	@mkdir -p $(BUILD_DIR)/AppIcon.iconset
	@sips -z 16 16 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_16x16.png > /dev/null
	@sips -z 32 32 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_16x16@2x.png > /dev/null
	@sips -z 32 32 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_32x32.png > /dev/null
	@sips -z 64 64 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_32x32@2x.png > /dev/null
	@sips -z 128 128 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_128x128.png > /dev/null
	@sips -z 256 256 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_128x128@2x.png > /dev/null
	@sips -z 256 256 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_256x256.png > /dev/null
	@sips -z 512 512 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_256x256@2x.png > /dev/null
	@sips -z 512 512 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_512x512.png > /dev/null
	@sips -z 1024 1024 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_512x512@2x.png > /dev/null
	@iconutil -c icns -o $@ $(BUILD_DIR)/AppIcon.iconset
	@rm -rf $(BUILD_DIR)/AppIcon.iconset
	@echo "Generated $@"

dmg: all
	@rm -f "$(BUILD_DIR)/$(APP_NAME).dmg"
	@rm -rf $(BUILD_DIR)/dmg-staging
	@mkdir -p $(BUILD_DIR)/dmg-staging
	@cp -R "$(APP_BUNDLE)" $(BUILD_DIR)/dmg-staging/
	@osascript -e 'tell application "Finder" to make alias file to POSIX file "/Applications" at POSIX file "'"$$(cd $(BUILD_DIR)/dmg-staging && pwd)"'"'
	@ALIAS=$$(find $(BUILD_DIR)/dmg-staging -maxdepth 1 -not -name '*.app' -not -name '.DS_Store' -type f | head -1) && mv "$$ALIAS" "$(BUILD_DIR)/dmg-staging/Applications"
	@fileicon set "$(BUILD_DIR)/dmg-staging/Applications" /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns
	@echo "Creating DMG..."
	@create-dmg \
		--volname "$(APP_NAME)" \
		--volicon "$(ICON_ICNS)" \
		--window-pos 200 120 \
		--window-size 660 400 \
		--icon-size 128 \
		--icon "$(APP_NAME).app" 180 170 \
		--hide-extension "$(APP_NAME).app" \
		--icon "Applications" 480 170 \
		--no-internet-enable \
		"$(BUILD_DIR)/$(APP_NAME).dmg" \
		"$(BUILD_DIR)/dmg-staging"
	@rm -rf $(BUILD_DIR)/dmg-staging
	@echo "Created $(BUILD_DIR)/$(APP_NAME).dmg"

codesign-dmg: dmg
	codesign --force --sign "$(CODESIGN_IDENTITY)" "$(BUILD_DIR)/$(APP_NAME).dmg"

notarize:
	xcrun notarytool submit "$(BUILD_DIR)/$(APP_NAME).dmg" \
		--keychain-profile "$(NOTARIZE_PROFILE)" --wait
	xcrun stapler staple "$(BUILD_DIR)/$(APP_NAME).dmg"

clean:
	rm -rf $(BUILD_DIR)

# Overwrite the installed app in place so macOS app permissions are preserved.
install: all
	@mkdir -p "/Applications/$(APP_NAME).app"
	@ditto "$(APP_BUNDLE)" "/Applications/$(APP_NAME).app"
	@echo "Installed $(APP_NAME).app to /Applications"

reset-permissions:
	tccutil reset All "$(BUNDLE_ID)"

install-and-run: install
	@if pgrep -fl "/Applications/$(APP_NAME).app|$(APP_NAME)" >/dev/null; then \
		pkill -f "/Applications/$(APP_NAME).app|$(APP_NAME)"; \
		sleep 1; \
	fi
	@open "/Applications/$(APP_NAME).app"

run: all
	open "$(APP_BUNDLE)"

FORCE:

test:
	@swiftc -parse-as-library Sources/CalendarIntegrationModels.swift Sources/CalendarEventMatcher.swift Tests/CalendarEventMatcherTests.swift -o /tmp/CalendarEventMatcherTests
	@/tmp/CalendarEventMatcherTests
	@swiftc -parse-as-library Sources/CalendarIntegrationModels.swift Sources/PipelineHistoryItem.swift Sources/NoteTitleResolver.swift Tests/NoteTitleResolutionTests.swift -o /tmp/NoteTitleResolutionTests
	@/tmp/NoteTitleResolutionTests
	@swiftc -parse-as-library Sources/AppName.swift Sources/CalendarIntegrationModels.swift Sources/PipelineHistoryItem.swift Sources/TranscriptionModel.swift Sources/PipelineHistoryStore.swift Tests/PipelineHistoryCalendarMetadataTests.swift -o /tmp/PipelineHistoryCalendarMetadataTests
	@/tmp/PipelineHistoryCalendarMetadataTests
	@swiftc -parse-as-library Sources/CalendarIntegrationModels.swift Sources/GoogleCalendarTokenStore.swift Sources/GoogleCalendarAuthService.swift Sources/GoogleCalendarService.swift Tests/GoogleCalendarServiceTests.swift -o /tmp/GoogleCalendarServiceTests
	@/tmp/GoogleCalendarServiceTests
	@swiftc -parse-as-library Sources/CalendarIntegrationModels.swift Sources/AppNotificationManager.swift Sources/CalendarRecordingReminderScheduler.swift Tests/CalendarRecordingReminderSchedulerTests.swift -o /tmp/CalendarRecordingReminderSchedulerTests
	@/tmp/CalendarRecordingReminderSchedulerTests
	@swiftc -parse-as-library Sources/TranscriptionModel.swift Sources/SetupFlow.swift Tests/SetupFlowTests.swift -o /tmp/SetupFlowTests
	@/tmp/SetupFlowTests
	@swiftc -parse-as-library -target $(shell uname -m)-apple-macosx13.0 $(filter-out Sources/App.swift,$(SOURCES)) Tests/AppStateTranscriptionConfigurationTests.swift -o /tmp/AppStateTranscriptionConfigurationTests
	@/tmp/AppStateTranscriptionConfigurationTests

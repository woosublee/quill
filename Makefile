-include version.mk

APP_NAME ?= Quill
BUNDLE_ID ?= com.woosublee.quill
DEV_APP_NAME ?= Quill Dev
DEV_BUNDLE_ID ?= com.woosublee.quill.dev
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CODESIGN_IDENTITY ?= Quill
GIT_RELEASE_TAG := $(shell git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null)
GIT_SHORT_SHA := $(shell git rev-parse --short HEAD 2>/dev/null)
APP_VERSION ?= $(patsubst v%,%,$(if $(GIT_RELEASE_TAG),$(GIT_RELEASE_TAG),v0.0.1))
BUILD_NUMBER ?= 1
BUILD_TAG ?= $(if $(GIT_SHORT_SHA),local-$(GIT_SHORT_SHA),local-unknown)
GOOGLE_CALENDAR_OAUTH_CLIENT_ID ?=
GOOGLE_CALENDAR_OAUTH_CLIENT_SECRET ?=
-include $(HOME)/.config/quill/oauth.env
-include .env
CONTENTS = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS)/MacOS
FRAMEWORKS = $(CONTENTS)/Frameworks
BUILD_SETTINGS = $(BUILD_DIR)/.build-settings
SPARKLE_STAMP = $(BUILD_DIR)/.sparkle-framework
SPARKLE_VERSION ?= 2.9.2
SPARKLE_FRAMEWORK_FIND = find .build/artifacts -path '*/Sparkle.framework' -type d -print -quit
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
.PHONY: all clean run icon dmg codesign-dmg notarize install reset-permissions install-and-run test print-app-version print-build-number print-build-tag print-version-metadata FORCE

all: $(APP_EXECUTABLE_TARGET)

$(BUILD_SETTINGS): FORCE
	@mkdir -p "$(BUILD_DIR)"
	@printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$(APP_NAME)" "$(BUNDLE_ID)" "$(APP_VERSION)" "$(BUILD_NUMBER)" "$(BUILD_TAG)" "$(GOOGLE_CALENDAR_OAUTH_CLIENT_ID)" "$(GOOGLE_CALENDAR_OAUTH_CLIENT_SECRET)" "$(CODESIGN_IDENTITY)" > "$@.tmp"
	@if [ ! -f "$@" ] || ! cmp -s "$@.tmp" "$@"; then mv "$@.tmp" "$@"; else rm "$@.tmp"; fi

$(SPARKLE_STAMP): Package.swift BuildSupport/SparkleResolver/main.swift
	@swift build --product SparkleResolver >/dev/null
	@mkdir -p "$(BUILD_DIR)"
	@framework="$$($(SPARKLE_FRAMEWORK_FIND))"; \
		if [ -z "$$framework" ]; then \
			echo "Missing Sparkle.framework artifact after swift build." >&2; \
			exit 1; \
		fi; \
		printf '%s\n' "$$framework" > "$@"

$(APP_EXECUTABLE_TARGET): $(SOURCES) Info.plist $(ICON_ICNS) $(BUILD_SETTINGS) $(SPARKLE_STAMP)
	@mkdir -p "$(MACOS_DIR)" "$(RESOURCES)" "$(FRAMEWORKS)"
	@framework="$$(cat "$(SPARKLE_STAMP)" 2>/dev/null)"; \
		if [ -z "$$framework" ] || [ ! -d "$$framework" ]; then \
			echo "Missing Sparkle.framework artifact. Run swift package resolve first." >&2; \
			exit 1; \
		fi; \
		rm -rf "$(FRAMEWORKS)/Sparkle.framework"; \
		ditto --norsrc --noextattr "$$framework" "$(FRAMEWORKS)/Sparkle.framework"
ifeq ($(ARCH),universal)
	@framework="$$(cat "$(SPARKLE_STAMP)" 2>/dev/null)"; framework_parent="$$(dirname "$$framework")"; \
	swiftc \
		-parse-as-library \
		-F "$$framework_parent" \
		-framework Sparkle \
		-Xlinker -rpath -Xlinker @executable_path/../Frameworks \
		-o "$(MACOS_DIR)/$(APP_NAME)-arm64" \
		-sdk $(shell xcrun --sdk macosx --show-sdk-path) \
		-target arm64-apple-macosx13.0 \
		$(SOURCES)
	@framework="$$(cat "$(SPARKLE_STAMP)" 2>/dev/null)"; framework_parent="$$(dirname "$$framework")"; \
	swiftc \
		-parse-as-library \
		-F "$$framework_parent" \
		-framework Sparkle \
		-Xlinker -rpath -Xlinker @executable_path/../Frameworks \
		-o "$(MACOS_DIR)/$(APP_NAME)-x86_64" \
		-sdk $(shell xcrun --sdk macosx --show-sdk-path) \
		-target x86_64-apple-macosx13.0 \
		$(SOURCES)
	lipo -create -output "$(MACOS_DIR)/$(APP_NAME)" \
		"$(MACOS_DIR)/$(APP_NAME)-arm64" \
		"$(MACOS_DIR)/$(APP_NAME)-x86_64"
	@rm "$(MACOS_DIR)/$(APP_NAME)-arm64" "$(MACOS_DIR)/$(APP_NAME)-x86_64"
else
	@framework="$$(cat "$(SPARKLE_STAMP)" 2>/dev/null)"; framework_parent="$$(dirname "$$framework")"; \
	swiftc \
		-parse-as-library \
		-F "$$framework_parent" \
		-framework Sparkle \
		-Xlinker -rpath -Xlinker @executable_path/../Frameworks \
		-o "$(MACOS_DIR)/$(APP_NAME)" \
		-sdk $(shell xcrun --sdk macosx --show-sdk-path) \
		-target $(ARCH)-apple-macosx13.0 \
		$(SOURCES)
endif
	@cp Info.plist "$(CONTENTS)/"
	@plutil -replace CFBundleName -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleDisplayName -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleExecutable -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleIdentifier -string "$(BUNDLE_ID)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleShortVersionString -string "$(APP_VERSION)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleVersion -string "$(BUILD_NUMBER)" "$(CONTENTS)/Info.plist"
	@plutil -replace QuillBuildTag -string "$(BUILD_TAG)" "$(CONTENTS)/Info.plist"
	@plutil -replace GoogleCalendarOAuthClientID -string "$(GOOGLE_CALENDAR_OAUTH_CLIENT_ID)" "$(CONTENTS)/Info.plist"
	@plutil -replace GoogleCalendarOAuthClientSecret -string "$(GOOGLE_CALENDAR_OAUTH_CLIENT_SECRET)" "$(CONTENTS)/Info.plist"
	@cp $(ICON_ICNS) "$(RESOURCES)/AppIcon.icns"
	@xattr -cr "$(APP_BUNDLE)"
	@rm -rf "$(BUILD_DIR)/codesign-staging"
	@mkdir -p "$(BUILD_DIR)/codesign-staging"
	@ditto --norsrc --noextattr "$(APP_BUNDLE)" "$(BUILD_DIR)/codesign-staging/$(APP_NAME).app"
	@xattr -cr "$(BUILD_DIR)/codesign-staging/$(APP_NAME).app"
	@staged_framework="$(BUILD_DIR)/codesign-staging/$(APP_NAME).app/Contents/Frameworks/Sparkle.framework"; \
		if [ -d "$$staged_framework/Versions/Current/XPCServices" ]; then \
			find -L "$$staged_framework/Versions/Current/XPCServices" -maxdepth 1 -name '*.xpc' -type d -exec codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" {} \; ; \
		fi; \
		if [ -d "$$staged_framework/Versions/Current/Updater.app" ]; then \
			codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" "$$staged_framework/Versions/Current/Updater.app"; \
		fi; \
		if [ -x "$$staged_framework/Versions/Current/Autoupdate" ]; then \
			codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" "$$staged_framework/Versions/Current/Autoupdate"; \
		fi; \
		codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" "$$staged_framework"
	@codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" --entitlements Quill.entitlements "$(BUILD_DIR)/codesign-staging/$(APP_NAME).app"
	@rm -rf "$(APP_BUNDLE)"
	@ditto --norsrc --noextattr "$(BUILD_DIR)/codesign-staging/$(APP_NAME).app" "$(APP_BUNDLE)"
	@xattr -cr "$(APP_BUNDLE)"
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
	@rm -f "$(BUILD_DIR)/$(APP_NAME).dmg" "$(BUILD_DIR)/$(APP_NAME)-rw.dmg"
	@rm -rf "$(BUILD_DIR)/dmg-mount"
	@mkdir -p "$(BUILD_DIR)/dmg-mount"
	@echo "Creating DMG..."
	@set -e; \
		mount_dir="$(BUILD_DIR)/dmg-mount"; \
		rw_dmg="$(BUILD_DIR)/$(APP_NAME)-rw.dmg"; \
		dmg_size_mb=$$(($$(du -sm "$(APP_BUNDLE)" | cut -f1) + 64)); \
		xattr -cr "$(APP_BUNDLE)"; \
		hdiutil create -size "$${dmg_size_mb}m" -fs HFS+ -volname "$(APP_NAME)" -ov "$$rw_dmg" >/dev/null; \
		hdiutil attach "$$rw_dmg" -nobrowse -mountpoint "$$mount_dir" >/dev/null; \
		trap 'hdiutil detach "$$mount_dir" >/dev/null 2>&1 || true; rm -f "$$rw_dmg"; rm -rf "$$mount_dir"' EXIT; \
		ditto --norsrc --noextattr "$(APP_BUNDLE)" "$$mount_dir/$(APP_NAME).app"; \
		ln -s /Applications "$$mount_dir/Applications"; \
		xattr -cr "$$mount_dir/$(APP_NAME).app"; \
		codesign --verify --deep --strict --verbose=2 "$$mount_dir/$(APP_NAME).app" >/dev/null; \
		hdiutil detach "$$mount_dir" >/dev/null; \
		hdiutil convert "$$rw_dmg" -format UDZO -o "$(BUILD_DIR)/$(APP_NAME).dmg" >/dev/null; \
		rm -f "$$rw_dmg"; \
		rm -rf "$$mount_dir"; \
		trap - EXIT
	@xattr -cr "$(APP_BUNDLE)"
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

run:
	$(MAKE) all APP_NAME="$(DEV_APP_NAME)" BUNDLE_ID="$(DEV_BUNDLE_ID)"
	open "$(BUILD_DIR)/$(DEV_APP_NAME).app"

print-app-version:
	@printf '%s\n' "$(APP_VERSION)"

print-build-number:
	@printf '%s\n' "$(BUILD_NUMBER)"

print-build-tag:
	@printf '%s\n' "$(BUILD_TAG)"

print-version-metadata:
	@printf 'app_version=%s\nbuild_number=%s\nbuild_tag=%s\n' "$(APP_VERSION)" "$(BUILD_NUMBER)" "$(BUILD_TAG)"

FORCE:

test: $(SPARKLE_STAMP)
	@swiftc -parse-as-library Sources/CalendarIntegrationModels.swift Sources/CalendarEventMatcher.swift Tests/CalendarEventMatcherTests.swift -o /tmp/CalendarEventMatcherTests
	@swiftc -parse-as-library Sources/AppName.swift Sources/ModifierKeyEventState.swift Sources/ShortcutCore/ShortcutModels.swift Sources/ShortcutCore/ShortcutMatcher.swift Sources/GlobalShortcutBackend.swift Sources/HotkeyManager.swift Tests/ShortcutMatcherTests.swift -o /tmp/ShortcutMatcherTests
	@swiftc -parse-as-library Sources/ShortcutCore/ShortcutModels.swift Sources/ShortcutBinding.swift Sources/ShortcutCaptureKeyHandling.swift Tests/ShortcutCaptureKeyHandlingTests.swift -o /tmp/ShortcutCaptureKeyHandlingTests
	@swiftc -parse-as-library Sources/ShortcutValidationMessages.swift Tests/ShortcutValidationMessagesTests.swift -o /tmp/ShortcutValidationMessagesTests
	@/tmp/ShortcutMatcherTests
	@/tmp/ShortcutCaptureKeyHandlingTests
	@/tmp/ShortcutValidationMessagesTests
	@/tmp/CalendarEventMatcherTests
	@swiftc -parse-as-library Sources/CalendarIntegrationModels.swift Sources/PipelineHistoryItem.swift Sources/NoteTitleResolver.swift Tests/NoteTitleResolutionTests.swift -o /tmp/NoteTitleResolutionTests
	@/tmp/NoteTitleResolutionTests
	@swiftc -parse-as-library Sources/CalendarIntegrationModels.swift Sources/PipelineHistoryItem.swift Sources/MeetingSourcePayload.swift Tests/MeetingSourcePayloadTests.swift -o /tmp/MeetingSourcePayloadTests
	@/tmp/MeetingSourcePayloadTests
	@swiftc -parse-as-library Sources/CalendarIntegrationModels.swift Sources/PipelineHistoryItem.swift Sources/NoteTitleResolver.swift Sources/NoteListRowDisplayData.swift Tests/NoteListRowDisplayDataTests.swift -o /tmp/NoteListRowDisplayDataTests
	@/tmp/NoteListRowDisplayDataTests
	@swiftc -parse-as-library Sources/CalendarIntegrationModels.swift Sources/PipelineHistoryItem.swift Sources/LegacyNoteTitleMigration.swift Tests/LegacyNoteTitleMigrationTests.swift -o /tmp/LegacyNoteTitleMigrationTests
	@/tmp/LegacyNoteTitleMigrationTests
	@swiftc -parse-as-library Tests/ManualReleaseWorkflowTests.swift -o /tmp/ManualReleaseWorkflowTests
	@/tmp/ManualReleaseWorkflowTests
	@framework="$$(cat "$(SPARKLE_STAMP)")"; framework_parent="$$(dirname "$$framework")"; swiftc -parse-as-library -F "$$framework_parent" -framework Sparkle -Xlinker -rpath -Xlinker "$$framework_parent" Sources/UpdateManager.swift Tests/UpdateManagerSafetyTests.swift -o /tmp/UpdateManagerSafetyTests
	@/tmp/UpdateManagerSafetyTests
	@swiftc -parse-as-library Tests/BuildMetadataTests.swift -o /tmp/BuildMetadataTests
	@/tmp/BuildMetadataTests
	@swiftc -parse-as-library Sources/InstructionExecutionDetector.swift Tests/InstructionExecutionDetectorTests.swift -o /tmp/InstructionExecutionDetectorTests
	@/tmp/InstructionExecutionDetectorTests
	@swiftc -parse-as-library Tests/ReleaseSDKCompatibilityTests.swift -o /tmp/ReleaseSDKCompatibilityTests
	@/tmp/ReleaseSDKCompatibilityTests
	@swiftc -parse-as-library Sources/AudioInputDevice.swift Tests/SystemAudioInputSelectionTests.swift -o /tmp/SystemAudioInputSelectionTests
	@/tmp/SystemAudioInputSelectionTests
	@swiftc -parse-as-library Tests/SystemAudioRecorderSourceTests.swift -o /tmp/SystemAudioRecorderSourceTests
	@/tmp/SystemAudioRecorderSourceTests
	@swiftc -parse-as-library Tests/SystemDefaultAndSystemAudioRecorderSourceTests.swift -o /tmp/SystemDefaultAndSystemAudioRecorderSourceTests
	@/tmp/SystemDefaultAndSystemAudioRecorderSourceTests
	@swiftc -parse-as-library "$(CURDIR)/Sources/AudioMixdownService.swift" "$(CURDIR)/Tests/AudioMixdownServiceTests.swift" -o /tmp/AudioMixdownServiceTests
	@/tmp/AudioMixdownServiceTests
	@swiftc -parse-as-library Sources/AudioWaveformHeights.swift Tests/AudioWaveformHeightsTests.swift -o /tmp/AudioWaveformHeightsTests
	@/tmp/AudioWaveformHeightsTests
	@swiftc -parse-as-library Tests/SystemAudioAppStateRoutingTests.swift -o /tmp/SystemAudioAppStateRoutingTests
	@/tmp/SystemAudioAppStateRoutingTests
	@swiftc -parse-as-library Sources/AppName.swift Sources/CalendarIntegrationModels.swift Sources/PipelineHistoryItem.swift Sources/TranscriptionModel.swift Sources/PipelineHistoryStore.swift Tests/PipelineHistoryCalendarMetadataTests.swift -o /tmp/PipelineHistoryCalendarMetadataTests
	@/tmp/PipelineHistoryCalendarMetadataTests
	@swiftc -parse-as-library Sources/CalendarIntegrationModels.swift Sources/GoogleCalendarTokenStore.swift Sources/GoogleCalendarAuthService.swift Sources/GoogleCalendarService.swift Tests/GoogleCalendarServiceTests.swift -o /tmp/GoogleCalendarServiceTests
	@/tmp/GoogleCalendarServiceTests
	@swiftc -parse-as-library Sources/CalendarIntegrationModels.swift Sources/AppNotificationManager.swift Sources/CalendarRecordingReminderScheduler.swift Tests/CalendarRecordingReminderSchedulerTests.swift -o /tmp/CalendarRecordingReminderSchedulerTests
	@/tmp/CalendarRecordingReminderSchedulerTests
	@swiftc -parse-as-library Sources/TranscriptionModel.swift Sources/SetupFlow.swift Tests/SetupFlowTests.swift -o /tmp/SetupFlowTests
	@/tmp/SetupFlowTests
	@swiftc -parse-as-library Sources/TranscriptionModel.swift Tests/TranscriptionModelCacheTests.swift -o /tmp/TranscriptionModelCacheTests
	@/tmp/TranscriptionModelCacheTests
	@swiftc -parse-as-library Sources/OverlayScreenGeometry.swift Tests/OverlayScreenGeometryTests.swift -o /tmp/OverlayScreenGeometryTests
	@/tmp/OverlayScreenGeometryTests
	@swiftc -parse-as-library Sources/OverlayScreenGeometry.swift Sources/FixedIntrinsicHostingView.swift Sources/ShortcutCore/ShortcutModels.swift Sources/AudioInputDevice.swift Sources/RecordingOverlay.swift Tests/RecordingOverlayGeometryTests.swift -o /tmp/RecordingOverlayGeometryTests
	@/tmp/RecordingOverlayGeometryTests
	@swiftc -parse-as-library Tests/UpstreamMergeBehaviorTests.swift -o /tmp/UpstreamMergeBehaviorTests
	@/tmp/UpstreamMergeBehaviorTests
	@swiftc -parse-as-library Sources/OverlayScreenGeometry.swift Sources/FixedIntrinsicHostingView.swift Sources/ShortcutCore/ShortcutModels.swift Sources/AudioInputDevice.swift Sources/RecordingOverlay.swift Sources/CalendarIntegrationModels.swift Sources/AppNotificationManager.swift Sources/CalendarRecordingReminderScheduler.swift Sources/MeetingReminderOverlay.swift Tests/MeetingReminderOverlayGeometryTests.swift -o /tmp/MeetingReminderOverlayGeometryTests
	@/tmp/MeetingReminderOverlayGeometryTests
	@framework="$$(cat "$(SPARKLE_STAMP)")"; framework_parent="$$(dirname "$$framework")"; swiftc -parse-as-library -F "$$framework_parent" -framework Sparkle -Xlinker -rpath -Xlinker "$$framework_parent" -target $(shell uname -m)-apple-macosx13.0 $(filter-out Sources/App.swift,$(SOURCES)) Tests/AppStateTranscriptionConfigurationTests.swift -o /tmp/AppStateTranscriptionConfigurationTests
	@/tmp/AppStateTranscriptionConfigurationTests

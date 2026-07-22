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
WHISPER_CPP_VERSION ?= v1.9.1
WHISPER_CPP_REPO ?= https://github.com/ggml-org/whisper.cpp.git
WHISPER_CPP_DIR = .build/checkouts/whisper.cpp
WHISPER_HELPER = $(WHISPER_CPP_DIR)/build/bin/whisper-cli
WHISPER_STAMP = $(BUILD_DIR)/.whisper-helper
WHISPER_BUILD_SETTINGS = $(BUILD_DIR)/.whisper-build-settings
WHISPER_VERIFY_SCRIPT = BuildSupport/WhisperRuntime/verify-whisper-helper.sh
LLAMA_CPP_VERSION ?= b4406
LLAMA_CPP_REPO ?= https://github.com/ggml-org/llama.cpp.git
LLAMA_CPP_DIR = .build/checkouts/llama.cpp
LLAMA_HELPER = $(LLAMA_CPP_DIR)/build/bin/llama-server
LLAMA_STAMP = $(BUILD_DIR)/.llama-server-helper
LLAMA_BUILD_SETTINGS = $(BUILD_DIR)/.llama-build-settings
LLAMA_VERIFY_SCRIPT = BuildSupport/LlamaRuntime/verify-llama-server.sh
empty :=
space := $(empty) $(empty)
APP_EXECUTABLE = $(MACOS_DIR)/$(APP_NAME)
APP_EXECUTABLE_TARGET := $(subst $(space),\ ,$(APP_EXECUTABLE))

SOURCES = $(shell find Sources -name '*.swift' -type f | LC_ALL=C sort)
RESOURCES = $(CONTENTS)/Resources
LOCALIZATION_CATALOG = Resources/Localization/Localizable.xcstrings
LOCALIZATION_INFO_DIR = Resources/Localization
LOCALIZATION_BUILD_DIR = $(BUILD_DIR)/localization
LOCALIZATION_STAMP = $(LOCALIZATION_BUILD_DIR)/.compiled
TEST_BUILD_DIR = $(BUILD_DIR)/tests
FULL_SOURCE_TRANSCRIPTION_TESTS = \
	Tests/CloudTranscriptionHistoryLifecycleTests.swift \
	Tests/TranscriptionServiceCloudChunkingTests.swift \
	Tests/TranscriptionServiceLocalIssueTests.swift \
	Tests/PostProcessingUserIssueTests.swift
FULL_SOURCE_APP_STATE_TESTS = \
	Tests/AudioImportFileCopyTests.swift \
	Tests/AppStateTranscriptionConfigurationTests.swift
GROUPED_TEST_SOURCES = $(FULL_SOURCE_TRANSCRIPTION_TESTS) $(FULL_SOURCE_APP_STATE_TESTS)
GROUPED_RUNNER_SOURCES = Tests/FullSourceTranscriptionTestRunner.swift Tests/FullSourceAppStateTestRunner.swift
FULL_SOURCE_TRANSCRIPTION_RUNNER = $(TEST_BUILD_DIR)/FullSourceTranscriptionTestRunner
FULL_SOURCE_APP_STATE_RUNNER = $(TEST_BUILD_DIR)/FullSourceAppStateTestRunner
RUN_TIMED_TARGET = start=$$(date +%s); status=0; $(MAKE) --no-print-directory $(1) || status=$$?; end=$$(date +%s); printf '[timing] shard=%s seconds=%s status=%s\n' "$(2)" "$$((end - start))" "$$status"; exit "$$status"
ARCH ?= $(shell uname -m)
TEST_ARCH = $(if $(filter universal,$(ARCH)),$(shell uname -m),$(ARCH))

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
.PHONY: all clean run icon dmg codesign-dmg notarize install reset-permissions install-and-run check-test-wiring test test-core test-recording test-transcription _test-core _test-recording _test-transcription localization-bundle-test native-whisper-helper-test llama-server-helper-test print-app-version print-build-number print-build-tag print-version-metadata FORCE

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

$(WHISPER_BUILD_SETTINGS): FORCE
	@mkdir -p "$(BUILD_DIR)"
	@printf '%s\n%s\n%s\n' "$(WHISPER_CPP_REPO)" "$(WHISPER_CPP_VERSION)" "$(ARCH)" > "$@.tmp"
	@if [ ! -f "$@" ] || ! cmp -s "$@.tmp" "$@"; then mv "$@.tmp" "$@"; else rm "$@.tmp"; fi

$(WHISPER_STAMP): BuildSupport/WhisperRuntime/build-whisper.cpp.sh $(WHISPER_VERIFY_SCRIPT) $(WHISPER_BUILD_SETTINGS)
	@BuildSupport/WhisperRuntime/build-whisper.cpp.sh "$(WHISPER_CPP_REPO)" "$(WHISPER_CPP_VERSION)" "$(WHISPER_CPP_DIR)" "$(ARCH)"
	@mkdir -p "$(BUILD_DIR)"
	@printf '%s\n' "$(WHISPER_HELPER)" > "$@"

native-whisper-helper-test: $(WHISPER_STAMP)
	@helper="$$(cat "$(WHISPER_STAMP)")"; \
		$(WHISPER_VERIFY_SCRIPT) "$$helper" "$(ARCH)"

$(LLAMA_BUILD_SETTINGS): FORCE
	@mkdir -p "$(BUILD_DIR)"
	@printf '%s\n%s\n%s\n' "$(LLAMA_CPP_REPO)" "$(LLAMA_CPP_VERSION)" "$(ARCH)" > "$@.tmp"
	@if [ ! -f "$@" ] || ! cmp -s "$@.tmp" "$@"; then mv "$@.tmp" "$@"; else rm "$@.tmp"; fi

$(LLAMA_STAMP): BuildSupport/LlamaRuntime/build-llama.cpp.sh $(LLAMA_VERIFY_SCRIPT) $(LLAMA_BUILD_SETTINGS)
	@BuildSupport/LlamaRuntime/build-llama.cpp.sh "$(LLAMA_CPP_REPO)" "$(LLAMA_CPP_VERSION)" "$(LLAMA_CPP_DIR)" "$(ARCH)"
	@mkdir -p "$(BUILD_DIR)"
	@printf '%s\n' "$(LLAMA_HELPER)" > "$@"

llama-server-helper-test: $(LLAMA_STAMP)
	@helper="$$(cat "$(LLAMA_STAMP)")"; \
		$(LLAMA_VERIFY_SCRIPT) "$$helper" "$(ARCH)"

$(LOCALIZATION_STAMP): $(LOCALIZATION_CATALOG) $(LOCALIZATION_INFO_DIR)/en.lproj/InfoPlist.strings $(LOCALIZATION_INFO_DIR)/ko.lproj/InfoPlist.strings
	@rm -rf "$(LOCALIZATION_BUILD_DIR)"
	@mkdir -p "$(LOCALIZATION_BUILD_DIR)"
	@xcrun xcstringstool compile "$(LOCALIZATION_CATALOG)" \
		--output-directory "$(LOCALIZATION_BUILD_DIR)" \
		-l en -l ko \
		--serialization-format text
	@for language in en ko; do \
		test -f "$(LOCALIZATION_BUILD_DIR)/$$language.lproj/Localizable.strings"; \
		cp "$(LOCALIZATION_INFO_DIR)/$$language.lproj/InfoPlist.strings" \
			"$(LOCALIZATION_BUILD_DIR)/$$language.lproj/InfoPlist.strings"; \
	done
	@touch "$@"

$(APP_EXECUTABLE_TARGET): $(SOURCES) Info.plist $(ICON_ICNS) $(BUILD_SETTINGS) $(SPARKLE_STAMP) $(WHISPER_STAMP) $(LLAMA_STAMP) $(LOCALIZATION_STAMP)
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
	@rm -rf "$(RESOURCES)/en.lproj" "$(RESOURCES)/ko.lproj"
	@ditto --norsrc --noextattr "$(LOCALIZATION_BUILD_DIR)/en.lproj" "$(RESOURCES)/en.lproj"
	@ditto --norsrc --noextattr "$(LOCALIZATION_BUILD_DIR)/ko.lproj" "$(RESOURCES)/ko.lproj"
	@mkdir -p "$(RESOURCES)/whisper"
	@whisper_helper="$$(cat "$(WHISPER_STAMP)")"; \
		if [ -z "$$whisper_helper" ] || [ ! -x "$$whisper_helper" ]; then \
			echo "Missing whisper.cpp helper at $$whisper_helper" >&2; \
			exit 1; \
		fi; \
		cp "$$whisper_helper" "$(RESOURCES)/whisper/whisper-cli"; \
		chmod 755 "$(RESOURCES)/whisper/whisper-cli"
	@mkdir -p "$(RESOURCES)/llama"
	@llama_helper="$$(cat "$(LLAMA_STAMP)")"; \
		if [ -z "$$llama_helper" ] || [ ! -x "$$llama_helper" ]; then \
			echo "Missing llama.cpp helper at $$llama_helper" >&2; \
			exit 1; \
		fi; \
		cp "$$llama_helper" "$(RESOURCES)/llama/llama-server"; \
		chmod 755 "$(RESOURCES)/llama/llama-server"
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
	@helper="$(BUILD_DIR)/codesign-staging/$(APP_NAME).app/Contents/Resources/whisper/whisper-cli"; \
		if [ -x "$$helper" ]; then \
			codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" "$$helper"; \
		else \
			echo "Missing bundled whisper helper in staging app." >&2; \
			exit 1; \
		fi
	@llama_helper="$(BUILD_DIR)/codesign-staging/$(APP_NAME).app/Contents/Resources/llama/llama-server"; \
		if [ -x "$$llama_helper" ]; then \
			codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" "$$llama_helper"; \
		else \
			echo "Missing bundled llama-server helper in staging app." >&2; \
			exit 1; \
		fi
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

check-test-wiring:
	@plan_file="$$(mktemp -t quill-test-plan)"; \
		trap 'rm -f "$$plan_file"' EXIT; \
		$(MAKE) -Bn --no-print-directory _test-core _test-recording _test-transcription > "$$plan_file"; \
		grouped_sources=" $(GROUPED_TEST_SOURCES) $(GROUPED_RUNNER_SOURCES) "; \
		for test_file in Tests/*.swift; do \
			compile_count="$$(grep -F -- "$$test_file" "$$plan_file" | grep -c 'swiftc ' || true)"; \
			if [ "$$compile_count" -ne 1 ]; then \
				echo "Test file must be compiled exactly once: $$test_file (found $$compile_count)" >&2; \
				exit 1; \
			fi; \
			case "$$grouped_sources" in \
				*" $$test_file "*) continue ;; \
			esac; \
			test_name="$${test_file##*/}"; \
			test_name="$${test_name%.swift}"; \
			if ! grep -Eq "^$(TEST_BUILD_DIR)/$$test_name([[:space:];]|$$)" "$$plan_file"; then \
				echo "Test executable is not run: $(TEST_BUILD_DIR)/$$test_name" >&2; \
				exit 1; \
			fi; \
		done; \
		for runner in $(FULL_SOURCE_TRANSCRIPTION_RUNNER) $(FULL_SOURCE_APP_STATE_RUNNER); do \
			runner_references="$$(grep -F -- "$$runner" "$$plan_file" | grep -Fv 'swiftc ' | wc -l | tr -d ' ')"; \
			if [ "$$runner_references" -lt 1 ]; then \
				echo "Grouped test runner is not executed: $$runner" >&2; \
				exit 1; \
			fi; \
		done

$(TEST_BUILD_DIR):
	@mkdir -p "$@"

$(TEST_BUILD_DIR)/LocalizationResourceTests: Tests/LocalizationResourceTests.swift | $(TEST_BUILD_DIR)
	@swiftc -parse-as-library Tests/LocalizationResourceTests.swift -o "$@"

$(FULL_SOURCE_TRANSCRIPTION_RUNNER): $(filter-out Sources/App.swift,$(SOURCES)) $(FULL_SOURCE_TRANSCRIPTION_TESTS) Tests/FullSourceTranscriptionTestRunner.swift Makefile $(SPARKLE_STAMP) | $(TEST_BUILD_DIR)
	@framework="$$(cat "$(SPARKLE_STAMP)")"; framework_parent="$$(dirname "$$framework")"; swiftc -parse-as-library -D QUILL_GROUPED_TEST_RUNNER -F "$$framework_parent" -framework Sparkle -Xlinker -rpath -Xlinker "$$framework_parent" -target $(TEST_ARCH)-apple-macosx13.0 $(filter-out Sources/App.swift,$(SOURCES)) $(FULL_SOURCE_TRANSCRIPTION_TESTS) Tests/FullSourceTranscriptionTestRunner.swift -o "$@"

$(FULL_SOURCE_APP_STATE_RUNNER): $(filter-out Sources/App.swift,$(SOURCES)) $(FULL_SOURCE_APP_STATE_TESTS) Tests/FullSourceAppStateTestRunner.swift Makefile $(SPARKLE_STAMP) | $(TEST_BUILD_DIR)
	@framework="$$(cat "$(SPARKLE_STAMP)")"; framework_parent="$$(dirname "$$framework")"; swiftc -parse-as-library -D QUILL_GROUPED_TEST_RUNNER -F "$$framework_parent" -framework Sparkle -Xlinker -rpath -Xlinker "$$framework_parent" -target $(TEST_ARCH)-apple-macosx13.0 $(filter-out Sources/App.swift,$(SOURCES)) $(FULL_SOURCE_APP_STATE_TESTS) Tests/FullSourceAppStateTestRunner.swift -o "$@"

localization-bundle-test: $(TEST_BUILD_DIR)/LocalizationResourceTests $(APP_EXECUTABLE_TARGET)
	@$(TEST_BUILD_DIR)/LocalizationResourceTests --bundle "$(APP_BUNDLE)"

test-core: check-test-wiring
	@$(call RUN_TIMED_TARGET,_test-core,core)

test-recording: check-test-wiring
	@$(call RUN_TIMED_TARGET,_test-recording,recording)

test-transcription: check-test-wiring
	@$(call RUN_TIMED_TARGET,_test-transcription,transcription)

test: check-test-wiring
	@$(call RUN_TIMED_TARGET,_test-core,core)
	@$(call RUN_TIMED_TARGET,_test-recording,recording)
	@$(call RUN_TIMED_TARGET,_test-transcription,transcription)

_test-core: $(SPARKLE_STAMP) $(LOCALIZATION_STAMP) $(TEST_BUILD_DIR)/LocalizationResourceTests | $(TEST_BUILD_DIR)
	@swiftc -parse-as-library Sources/CalendarIntegrationModels.swift Sources/CalendarEventMatcher.swift Tests/CalendarEventMatcherTests.swift -o $(TEST_BUILD_DIR)/CalendarEventMatcherTests
	@swiftc -parse-as-library Sources/AppName.swift Sources/ModifierKeyEventState.swift Sources/ShortcutCore/ShortcutModels.swift Sources/ShortcutCore/ShortcutMatcher.swift Sources/GlobalShortcutBackend.swift Sources/HotkeyManager.swift Tests/ShortcutMatcherTests.swift -o $(TEST_BUILD_DIR)/ShortcutMatcherTests
	@swiftc -parse-as-library Sources/ShortcutCore/ShortcutModels.swift Sources/ShortcutBinding.swift Sources/ShortcutCaptureKeyHandling.swift Tests/ShortcutCaptureKeyHandlingTests.swift -o $(TEST_BUILD_DIR)/ShortcutCaptureKeyHandlingTests
	@swiftc -parse-as-library Sources/ShortcutValidationMessages.swift Tests/ShortcutValidationMessagesTests.swift -o $(TEST_BUILD_DIR)/ShortcutValidationMessagesTests
	@$(TEST_BUILD_DIR)/ShortcutMatcherTests
	@$(TEST_BUILD_DIR)/ShortcutCaptureKeyHandlingTests
	@$(TEST_BUILD_DIR)/ShortcutValidationMessagesTests
	@$(TEST_BUILD_DIR)/CalendarEventMatcherTests
	@swiftc -parse-as-library Sources/RecordingJournalFailure.swift Sources/RecoveredRecordingContext.swift Sources/RecoveredRecordingMode.swift Sources/RecordingJournalModels.swift Sources/LocalizedStringLookup.swift Sources/CalendarIntegrationModels.swift Sources/QuillUserIssue.swift Sources/PipelineHistoryItem.swift Sources/NoteTitleResolver.swift Tests/NoteTitleResolutionTests.swift -o $(TEST_BUILD_DIR)/NoteTitleResolutionTests
	@$(TEST_BUILD_DIR)/NoteTitleResolutionTests
	@swiftc -parse-as-library Sources/RecordingJournalFailure.swift Sources/RecoveredRecordingContext.swift Sources/LocalizedStringLookup.swift Sources/RecoveredRecordingMode.swift Sources/RecordingJournalModels.swift Sources/CalendarIntegrationModels.swift Sources/QuillUserIssue.swift Sources/PipelineHistoryItem.swift Sources/MeetingSourcePayload.swift Tests/MeetingSourcePayloadTests.swift -o $(TEST_BUILD_DIR)/MeetingSourcePayloadTests
	@$(TEST_BUILD_DIR)/MeetingSourcePayloadTests
	@swiftc -parse-as-library Sources/RecordingJournalFailure.swift Sources/RecoveredRecordingContext.swift Sources/RecoveredRecordingMode.swift Sources/RecordingJournalModels.swift Sources/LocalizedStringLookup.swift Sources/CalendarIntegrationModels.swift Sources/QuillUserIssue.swift Sources/PipelineHistoryItem.swift Sources/NoteTitleResolver.swift Sources/NoteListRowDisplayData.swift Tests/NoteListRowDisplayDataTests.swift -o $(TEST_BUILD_DIR)/NoteListRowDisplayDataTests
	@$(TEST_BUILD_DIR)/NoteListRowDisplayDataTests
	@swiftc -parse-as-library Sources/RecordingJournalFailure.swift Sources/RecoveredRecordingContext.swift Sources/RecoveredRecordingMode.swift Sources/RecordingJournalModels.swift Sources/LocalizedStringLookup.swift Sources/QuillUserIssue.swift Sources/CalendarIntegrationModels.swift Sources/PipelineHistoryItem.swift Sources/NoteTitleResolver.swift Sources/NoteListRowDisplayData.swift Tests/PipelineHistoryUserIssueTests.swift -o $(TEST_BUILD_DIR)/PipelineHistoryUserIssueTests
	@$(TEST_BUILD_DIR)/PipelineHistoryUserIssueTests
	@swiftc -parse-as-library Tests/NoteTitleHorizontalScrollFieldTests.swift -o $(TEST_BUILD_DIR)/NoteTitleHorizontalScrollFieldTests
	@$(TEST_BUILD_DIR)/NoteTitleHorizontalScrollFieldTests
	@swiftc -parse-as-library Sources/RecordingJournalFailure.swift Sources/RecoveredRecordingContext.swift Sources/LocalizedStringLookup.swift Sources/RecoveredRecordingMode.swift Sources/RecordingJournalModels.swift Sources/CalendarIntegrationModels.swift Sources/QuillUserIssue.swift Sources/PipelineHistoryItem.swift Sources/LegacyNoteTitleMigration.swift Tests/LegacyNoteTitleMigrationTests.swift -o $(TEST_BUILD_DIR)/LegacyNoteTitleMigrationTests
	@$(TEST_BUILD_DIR)/LegacyNoteTitleMigrationTests
	@swiftc -parse-as-library Tests/ManualReleaseWorkflowTests.swift -o $(TEST_BUILD_DIR)/ManualReleaseWorkflowTests
	@$(TEST_BUILD_DIR)/ManualReleaseWorkflowTests
	@swiftc -parse-as-library Tests/NativeWhisperBuildContractTests.swift -o $(TEST_BUILD_DIR)/NativeWhisperBuildContractTests
	@$(TEST_BUILD_DIR)/NativeWhisperBuildContractTests
	@swiftc -parse-as-library Tests/LocalAIBuildContractTests.swift -o $(TEST_BUILD_DIR)/LocalAIBuildContractTests
	@$(TEST_BUILD_DIR)/LocalAIBuildContractTests
	@framework="$$(cat "$(SPARKLE_STAMP)")"; framework_parent="$$(dirname "$$framework")"; swiftc -parse-as-library -F "$$framework_parent" -framework Sparkle -Xlinker -rpath -Xlinker "$$framework_parent" Sources/LocalizedStringLookup.swift Sources/LocalizedUserMessage.swift Sources/UpdateManager.swift Tests/UpdateManagerSafetyTests.swift -o $(TEST_BUILD_DIR)/UpdateManagerSafetyTests
	@$(TEST_BUILD_DIR)/UpdateManagerSafetyTests
	@swiftc -parse-as-library Sources/LocalizedStringLookup.swift Tests/LocalizedStringLookupTests.swift -o $(TEST_BUILD_DIR)/LocalizedStringLookupTests
	@$(TEST_BUILD_DIR)/LocalizedStringLookupTests
	@swiftc -parse-as-library Sources/LocalizedStringLookup.swift Sources/LocalizedUserMessage.swift Tests/LocalizedUserMessageTests.swift -o $(TEST_BUILD_DIR)/LocalizedUserMessageTests
	@$(TEST_BUILD_DIR)/LocalizedUserMessageTests
	@swiftc -parse-as-library Sources/LocalizedStringLookup.swift Sources/QuillUserIssue.swift Tests/QuillUserIssueTests.swift -o $(TEST_BUILD_DIR)/QuillUserIssueTests
	@$(TEST_BUILD_DIR)/QuillUserIssueTests
	@swiftc -parse-as-library Sources/LocalizedStringLookup.swift Sources/QuillUserIssue.swift Sources/NoteBrowserRecovery.swift Tests/NoteBrowserRecoveryTests.swift -o $(TEST_BUILD_DIR)/NoteBrowserRecoveryTests
	@$(TEST_BUILD_DIR)/NoteBrowserRecoveryTests
	@swiftc -parse-as-library Sources/NoteFileExport.swift Tests/NoteFileExportTests.swift -o $(TEST_BUILD_DIR)/NoteFileExportTests
	@$(TEST_BUILD_DIR)/NoteFileExportTests
	@swiftc -parse-as-library Tests/NoteFileExportUIContractTests.swift -o $(TEST_BUILD_DIR)/NoteFileExportUIContractTests
	@$(TEST_BUILD_DIR)/NoteFileExportUIContractTests
	@swiftc -parse-as-library Sources/LocalizedStringLookup.swift Sources/OverlayDisplayCopy.swift Tests/OverlayDisplayCopyTests.swift -o $(TEST_BUILD_DIR)/OverlayDisplayCopyTests
	@$(TEST_BUILD_DIR)/OverlayDisplayCopyTests
	@swiftc -parse-as-library Tests/BuildMetadataTests.swift -o $(TEST_BUILD_DIR)/BuildMetadataTests
	@$(TEST_BUILD_DIR)/BuildMetadataTests
	@$(TEST_BUILD_DIR)/LocalizationResourceTests
	@swiftc -parse-as-library Sources/LocalizedStringLookup.swift Sources/TranscriptionLanguage.swift Sources/TranscriptionModel.swift Sources/NativeWhisperModel.swift Sources/AudioImportOptions.swift Tests/SettingsLocalizationTests.swift -o $(TEST_BUILD_DIR)/SettingsLocalizationTests
	@$(TEST_BUILD_DIR)/SettingsLocalizationTests
	@swiftc -parse-as-library Tests/ModelsSettingsUIContractTests.swift -o $(TEST_BUILD_DIR)/ModelsSettingsUIContractTests
	@$(TEST_BUILD_DIR)/ModelsSettingsUIContractTests
	@swiftc -parse-as-library Tests/QuillUserIssueUIContractTests.swift -o $(TEST_BUILD_DIR)/QuillUserIssueUIContractTests
	@$(TEST_BUILD_DIR)/QuillUserIssueUIContractTests
	@swiftc -parse-as-library Sources/CanonicalPCM16WAV.swift Tests/CanonicalPCM16WAVTests.swift -o $(TEST_BUILD_DIR)/CanonicalPCM16WAVTests
	@$(TEST_BUILD_DIR)/CanonicalPCM16WAVTests
	@swiftc -parse-as-library Sources/CanonicalPCM16WAV.swift Sources/CloudTranscriptionChunking.swift Tests/CloudTranscriptionChunkingTests.swift -o $(TEST_BUILD_DIR)/CloudTranscriptionChunkingTests
	@$(TEST_BUILD_DIR)/CloudTranscriptionChunkingTests
	@swiftc -parse-as-library Sources/CanonicalPCM16WAV.swift Sources/CloudTranscriptionChunking.swift Sources/CloudTranscriptionCore.swift Tests/CloudTranscriptionCoreTests.swift -o $(TEST_BUILD_DIR)/CloudTranscriptionCoreTests
	@$(TEST_BUILD_DIR)/CloudTranscriptionCoreTests
	@swiftc -parse-as-library Sources/CalendarIntegrationModels.swift Sources/RecordingJournalFailure.swift Sources/RecoveredRecordingContext.swift Sources/LocalizedStringLookup.swift Sources/RecoveredRecordingMode.swift Sources/RecordingJournalModels.swift Sources/TranscriptionModel.swift Sources/CanonicalPCM16WAV.swift Sources/CloudTranscriptionChunking.swift Sources/CloudTranscriptionCore.swift Sources/QuillUserIssue.swift Sources/PipelineHistoryItem.swift Sources/CloudTranscriptionJobStore.swift Tests/CloudTranscriptionJobStoreTests.swift -o $(TEST_BUILD_DIR)/CloudTranscriptionJobStoreTests
	@$(TEST_BUILD_DIR)/CloudTranscriptionJobStoreTests
	@swiftc -parse-as-library Sources/CalendarIntegrationModels.swift Sources/RecordingJournalFailure.swift Sources/RecoveredRecordingContext.swift Sources/LocalizedStringLookup.swift Sources/RecoveredRecordingMode.swift Sources/RecordingJournalModels.swift Sources/TranscriptionLanguage.swift Sources/TranscriptionModel.swift Sources/CanonicalPCM16WAV.swift Sources/CloudTranscriptionChunking.swift Sources/CloudTranscriptionCore.swift Sources/QuillUserIssue.swift Sources/PipelineHistoryItem.swift Sources/CloudTranscriptionJobStore.swift Sources/TranscriptionExecutionSnapshot.swift Tests/TranscriptionExecutionSnapshotTests.swift -o $(TEST_BUILD_DIR)/TranscriptionExecutionSnapshotTests
	@$(TEST_BUILD_DIR)/TranscriptionExecutionSnapshotTests
	@swiftc -parse-as-library Sources/CalendarIntegrationModels.swift Sources/RecordingJournalFailure.swift Sources/RecoveredRecordingContext.swift Sources/LocalizedStringLookup.swift Sources/RecoveredRecordingMode.swift Sources/RecordingJournalModels.swift Sources/TranscriptionLanguage.swift Sources/TranscriptionModel.swift Sources/CanonicalPCM16WAV.swift Sources/CloudTranscriptionChunking.swift Sources/CloudTranscriptionCore.swift Sources/QuillUserIssue.swift Sources/PipelineHistoryItem.swift Sources/CloudTranscriptionJobStore.swift Sources/NoteTitleResolver.swift Sources/NoteListRowDisplayData.swift Sources/TranscriptionExecutionSnapshot.swift Sources/CloudTranscriptionExecutionContext.swift Sources/CloudTranscriptionHistoryCoordinator.swift Tests/CloudTranscriptionHistoryCoordinatorTests.swift -o $(TEST_BUILD_DIR)/CloudTranscriptionHistoryCoordinatorTests
	@$(TEST_BUILD_DIR)/CloudTranscriptionHistoryCoordinatorTests
	@swiftc -parse-as-library Tests/AppStateCloudTranscriptionIntegrationSourceTests.swift -o $(TEST_BUILD_DIR)/AppStateCloudTranscriptionIntegrationSourceTests
	@$(TEST_BUILD_DIR)/AppStateCloudTranscriptionIntegrationSourceTests
	@swiftc -parse-as-library Tests/AppStateCloudTranscriptionCleanupSourceTests.swift -o $(TEST_BUILD_DIR)/AppStateCloudTranscriptionCleanupSourceTests
	@$(TEST_BUILD_DIR)/AppStateCloudTranscriptionCleanupSourceTests
	@swiftc -parse-as-library Tests/AppStateUserIssueLifecycleSourceTests.swift -o $(TEST_BUILD_DIR)/AppStateUserIssueLifecycleSourceTests
	@$(TEST_BUILD_DIR)/AppStateUserIssueLifecycleSourceTests
_test-recording: | $(TEST_BUILD_DIR)
	@swiftc -parse-as-library Sources/RecordingJournalFailure.swift Sources/RecoveredRecordingContext.swift Sources/LocalizedStringLookup.swift Sources/RecoveredRecordingMode.swift Sources/RecordingJournalModels.swift Tests/RecordingJournalFailureTests.swift -o $(TEST_BUILD_DIR)/RecordingJournalFailureTests
	@$(TEST_BUILD_DIR)/RecordingJournalFailureTests
	@swiftc -parse-as-library Sources/RecordingJournalFailure.swift Sources/RecoveredRecordingContext.swift Sources/LocalizedStringLookup.swift Sources/RecoveredRecordingMode.swift Sources/RecordingJournalModels.swift Sources/CanonicalPCM16WAV.swift Sources/RecordingJournalStore.swift Sources/RecordingPCMJournalWriter.swift Tests/RecordingPCMJournalWriterFailureTests.swift -o $(TEST_BUILD_DIR)/RecordingPCMJournalWriterFailureTests
	@$(TEST_BUILD_DIR)/RecordingPCMJournalWriterFailureTests
	@swiftc -parse-as-library Sources/RecordingJournalFailure.swift Sources/RecoveredRecordingContext.swift Sources/LocalizedStringLookup.swift Sources/RecoveredRecordingMode.swift Sources/RecordingJournalModels.swift Tests/RecordingJournalManifestTests.swift -o $(TEST_BUILD_DIR)/RecordingJournalManifestTests
	@$(TEST_BUILD_DIR)/RecordingJournalManifestTests
	@swiftc -parse-as-library Sources/RecordingMonotonicClock.swift Tests/RecordingMonotonicClockTests.swift -o $(TEST_BUILD_DIR)/RecordingMonotonicClockTests
	@$(TEST_BUILD_DIR)/RecordingMonotonicClockTests
	@swiftc -parse-as-library -framework AVFoundation Sources/RecordingJournalFailure.swift Sources/RecoveredRecordingContext.swift Sources/LocalizedStringLookup.swift Sources/RecoveredRecordingMode.swift Sources/RecordingJournalModels.swift Sources/CanonicalPCM16WAV.swift Sources/RecordingJournalStore.swift Sources/RecordingPCMJournalWriter.swift Sources/RecordingJournalSourceSink.swift Sources/CombinedRecordingJournalController.swift Sources/SegmentedRecordingJournalController.swift Sources/RecordingArtifactFinalizer.swift Sources/AudioMixdownService.swift Sources/CombinedRecordingArtifactFinalizer.swift Sources/SegmentedRecordingArtifactFinalizer.swift Sources/InflightRecordingRecovery.swift Sources/RecordingJournalRecoveryExecutor.swift Tests/RecordingJournalRuntimeTests.swift -o $(TEST_BUILD_DIR)/RecordingJournalRuntimeTests
	@$(TEST_BUILD_DIR)/RecordingJournalRuntimeTests
	@swiftc -parse-as-library Sources/RecordingJournalFailure.swift Sources/RecoveredRecordingContext.swift Sources/LocalizedStringLookup.swift Sources/RecoveredRecordingMode.swift Sources/RecordingJournalModels.swift Sources/CanonicalPCM16WAV.swift Sources/RecordingJournalStore.swift Sources/RecordingPCMJournalWriter.swift Sources/RecordingJournalSourceSink.swift Sources/CombinedRecordingJournalController.swift Tests/CombinedRecordingJournalControllerTests.swift -o $(TEST_BUILD_DIR)/CombinedRecordingJournalControllerTests
	@$(TEST_BUILD_DIR)/CombinedRecordingJournalControllerTests
	@swiftc -parse-as-library Sources/RecordingJournalFailure.swift Sources/RecoveredRecordingContext.swift Sources/LocalizedStringLookup.swift Sources/RecoveredRecordingMode.swift Sources/RecordingJournalModels.swift Sources/CanonicalPCM16WAV.swift Sources/RecordingJournalStore.swift Sources/RecordingPCMJournalWriter.swift Sources/RecordingJournalSourceSink.swift Sources/SegmentedRecordingJournalController.swift Tests/SegmentedRecordingJournalControllerTests.swift -o $(TEST_BUILD_DIR)/SegmentedRecordingJournalControllerTests
	@$(TEST_BUILD_DIR)/SegmentedRecordingJournalControllerTests
	@swiftc -parse-as-library -framework AVFoundation Sources/RecordingJournalFailure.swift Sources/RecoveredRecordingContext.swift Sources/LocalizedStringLookup.swift Sources/RecoveredRecordingMode.swift Sources/RecordingJournalModels.swift Sources/CanonicalPCM16WAV.swift Sources/RecordingJournalStore.swift Sources/RecordingPCMJournalWriter.swift Sources/RecordingJournalSourceSink.swift Sources/CombinedRecordingJournalController.swift Sources/SegmentedRecordingJournalController.swift Sources/RecordingArtifactFinalizer.swift Sources/AudioMixdownService.swift Sources/CombinedRecordingArtifactFinalizer.swift Tests/CombinedRecordingArtifactFinalizerTests.swift -o $(TEST_BUILD_DIR)/CombinedRecordingArtifactFinalizerTests
	@$(TEST_BUILD_DIR)/CombinedRecordingArtifactFinalizerTests
	@swiftc -parse-as-library -framework AVFoundation Sources/RecordingJournalFailure.swift Sources/RecoveredRecordingContext.swift Sources/LocalizedStringLookup.swift Sources/RecoveredRecordingMode.swift Sources/RecordingJournalModels.swift Sources/CanonicalPCM16WAV.swift Sources/RecordingJournalStore.swift Sources/RecordingPCMJournalWriter.swift Sources/RecordingJournalSourceSink.swift Sources/SegmentedRecordingJournalController.swift Sources/RecordingArtifactFinalizer.swift Sources/AudioMixdownService.swift Sources/SegmentedRecordingArtifactFinalizer.swift Tests/SegmentedRecordingArtifactFinalizerTests.swift -o $(TEST_BUILD_DIR)/SegmentedRecordingArtifactFinalizerTests
	@$(TEST_BUILD_DIR)/SegmentedRecordingArtifactFinalizerTests
	@swiftc -parse-as-library -framework AVFoundation Sources/RecordingJournalFailure.swift Sources/RecoveredRecordingContext.swift Sources/RecoveredRecordingMode.swift Sources/LocalizedStringLookup.swift Sources/RecordingJournalModels.swift Sources/CanonicalPCM16WAV.swift Sources/RecordingJournalStore.swift Sources/RecordingPCMJournalWriter.swift Sources/RecordingJournalSourceSink.swift Sources/SegmentedRecordingJournalController.swift Sources/RecordingArtifactFinalizer.swift Sources/AudioMixdownService.swift Sources/CombinedRecordingArtifactFinalizer.swift Sources/SegmentedRecordingArtifactFinalizer.swift Sources/InflightRecordingRecovery.swift Sources/RecordingJournalRecoveryExecutor.swift Tests/RecordingStorageFailureRecoveryIntegrationTests.swift -o $(TEST_BUILD_DIR)/RecordingStorageFailureRecoveryIntegrationTests
	@$(TEST_BUILD_DIR)/RecordingStorageFailureRecoveryIntegrationTests
	@swiftc -parse-as-library -framework AVFoundation Sources/RecordingJournalFailure.swift Sources/RecoveredRecordingContext.swift Sources/LocalizedStringLookup.swift Sources/RecoveredRecordingMode.swift Sources/RecordingJournalModels.swift Sources/CanonicalPCM16WAV.swift Sources/RecordingJournalStore.swift Sources/RecordingPCMJournalWriter.swift Sources/RecordingJournalSourceSink.swift Sources/CombinedRecordingJournalController.swift Sources/SegmentedRecordingJournalController.swift Sources/RecordingArtifactFinalizer.swift Sources/AudioMixdownService.swift Sources/CombinedRecordingArtifactFinalizer.swift Tests/CombinedRecordingNormalStopIntegrationTests.swift -o $(TEST_BUILD_DIR)/CombinedRecordingNormalStopIntegrationTests
	@$(TEST_BUILD_DIR)/CombinedRecordingNormalStopIntegrationTests
	@swiftc -parse-as-library -framework AVFoundation Sources/RecordingPCMBufferCopy.swift Tests/RecordingPCMBufferCopyTests.swift -o $(TEST_BUILD_DIR)/RecordingPCMBufferCopyTests
	@$(TEST_BUILD_DIR)/RecordingPCMBufferCopyTests
	@swiftc -parse-as-library Tests/AudioRecorderJournalIntegrationSourceTests.swift -o $(TEST_BUILD_DIR)/AudioRecorderJournalIntegrationSourceTests
	@$(TEST_BUILD_DIR)/AudioRecorderJournalIntegrationSourceTests
	@swiftc -parse-as-library -framework AVFoundation Sources/RecordingJournalFailure.swift Sources/RecoveredRecordingContext.swift Sources/LocalizedStringLookup.swift Sources/RecoveredRecordingMode.swift Sources/RecordingJournalModels.swift Sources/CanonicalPCM16WAV.swift Sources/RecordingJournalStore.swift Sources/RecordingPCMJournalWriter.swift Sources/RecordingJournalSourceSink.swift Sources/CombinedRecordingJournalController.swift Sources/SegmentedRecordingJournalController.swift Sources/RecordingArtifactFinalizer.swift Sources/AudioMixdownService.swift Sources/CombinedRecordingArtifactFinalizer.swift Sources/SegmentedRecordingArtifactFinalizer.swift Sources/InflightRecordingRecovery.swift Sources/RecordingJournalRecoveryExecutor.swift Sources/SingleSourceRecordingJournalController.swift Tests/SingleSourceRecordingJournalControllerTests.swift -o $(TEST_BUILD_DIR)/SingleSourceRecordingJournalControllerTests
	@$(TEST_BUILD_DIR)/SingleSourceRecordingJournalControllerTests
	@swiftc -parse-as-library -framework AVFoundation Sources/RecordingJournalFailure.swift Sources/RecoveredRecordingContext.swift Sources/LocalizedStringLookup.swift Sources/RecoveredRecordingMode.swift Sources/RecordingJournalModels.swift Sources/CanonicalPCM16WAV.swift Sources/RecordingJournalStore.swift Sources/RecordingPCMJournalWriter.swift Sources/RecordingJournalSourceSink.swift Sources/CombinedRecordingJournalController.swift Sources/SegmentedRecordingJournalController.swift Sources/RecordingArtifactFinalizer.swift Sources/AudioMixdownService.swift Sources/CombinedRecordingArtifactFinalizer.swift Sources/SegmentedRecordingArtifactFinalizer.swift Sources/InflightRecordingRecovery.swift Sources/SingleSourceRecordingJournalController.swift Sources/RecordingJournalRecoveryExecutor.swift Tests/RecordingJournalRecoveryExecutorTests.swift -o $(TEST_BUILD_DIR)/RecordingJournalRecoveryExecutorTests
	@$(TEST_BUILD_DIR)/RecordingJournalRecoveryExecutorTests
	@swiftc -parse-as-library -framework AVFoundation Sources/LocalizedStringLookup.swift Sources/AppName.swift Sources/CalendarIntegrationModels.swift Sources/QuillUserIssue.swift Sources/PipelineHistoryItem.swift Sources/TranscriptionModel.swift Sources/PipelineHistoryStore.swift Sources/RecordingJournalFailure.swift Sources/RecoveredRecordingContext.swift Sources/RecoveredRecordingMode.swift Sources/RecordingJournalModels.swift Sources/CanonicalPCM16WAV.swift Sources/RecordingJournalStore.swift Sources/RecordingPCMJournalWriter.swift Sources/RecordingJournalSourceSink.swift Sources/CombinedRecordingJournalController.swift Sources/SegmentedRecordingJournalController.swift Sources/RecordingArtifactFinalizer.swift Sources/AudioMixdownService.swift Sources/CombinedRecordingArtifactFinalizer.swift Sources/SegmentedRecordingArtifactFinalizer.swift Sources/InflightRecordingRecovery.swift Sources/SingleSourceRecordingJournalController.swift Sources/RecordingJournalRecoveryExecutor.swift Sources/RecordingRecoveryHistory.swift Tests/RecordingRecoveryHistoryTests.swift -o $(TEST_BUILD_DIR)/RecordingRecoveryHistoryTests
	@$(TEST_BUILD_DIR)/RecordingRecoveryHistoryTests
	@swiftc -parse-as-library Tests/AppStateRecordingJournalIntegrationSourceTests.swift -o $(TEST_BUILD_DIR)/AppStateRecordingJournalIntegrationSourceTests
	@$(TEST_BUILD_DIR)/AppStateRecordingJournalIntegrationSourceTests
	@swiftc -parse-as-library -framework AVFoundation Sources/RecordingJournalFailure.swift Sources/RecoveredRecordingContext.swift Sources/RecoveredRecordingMode.swift Sources/LocalizedStringLookup.swift Sources/AppName.swift Sources/CalendarIntegrationModels.swift Sources/QuillUserIssue.swift Sources/PipelineHistoryItem.swift Sources/TranscriptionModel.swift Sources/PipelineHistoryStore.swift Sources/RecordingJournalModels.swift Sources/CanonicalPCM16WAV.swift Sources/RecordingJournalStore.swift Sources/RecordingPCMJournalWriter.swift Sources/RecordingJournalSourceSink.swift Sources/CombinedRecordingJournalController.swift Sources/SegmentedRecordingJournalController.swift Sources/RecordingArtifactFinalizer.swift Sources/AudioMixdownService.swift Sources/CombinedRecordingArtifactFinalizer.swift Sources/SegmentedRecordingArtifactFinalizer.swift Sources/InflightRecordingRecovery.swift Sources/RecordingJournalRecoveryExecutor.swift Sources/RecordingRecoveryHistory.swift Tests/CombinedRecordingStartupRecoveryIntegrationTests.swift -o $(TEST_BUILD_DIR)/CombinedRecordingStartupRecoveryIntegrationTests
	@$(TEST_BUILD_DIR)/CombinedRecordingStartupRecoveryIntegrationTests
	@swiftc -parse-as-library -framework AVFoundation Sources/LocalizedStringLookup.swift Sources/AppName.swift Sources/CalendarIntegrationModels.swift Sources/QuillUserIssue.swift Sources/PipelineHistoryItem.swift Sources/TranscriptionModel.swift Sources/PipelineHistoryStore.swift Sources/RecordingJournalFailure.swift Sources/RecoveredRecordingContext.swift Sources/RecoveredRecordingMode.swift Sources/RecordingJournalModels.swift Sources/CanonicalPCM16WAV.swift Sources/RecordingJournalStore.swift Sources/RecordingPCMJournalWriter.swift Sources/RecordingJournalSourceSink.swift Sources/CombinedRecordingJournalController.swift Sources/SegmentedRecordingJournalController.swift Sources/RecordingArtifactFinalizer.swift Sources/AudioMixdownService.swift Sources/CombinedRecordingArtifactFinalizer.swift Sources/SegmentedRecordingArtifactFinalizer.swift Sources/InflightRecordingRecovery.swift Sources/RecordingJournalRecoveryExecutor.swift Sources/RecordingRecoveryHistory.swift Tests/SegmentedRecordingRecoveryIntegrationTests.swift -o $(TEST_BUILD_DIR)/SegmentedRecordingRecoveryIntegrationTests
	@$(TEST_BUILD_DIR)/SegmentedRecordingRecoveryIntegrationTests
	@swiftc -parse-as-library Tests/RecoveredRecordingNoteBrowserSourceTests.swift -o $(TEST_BUILD_DIR)/RecoveredRecordingNoteBrowserSourceTests
	@$(TEST_BUILD_DIR)/RecoveredRecordingNoteBrowserSourceTests
	@swiftc -parse-as-library Sources/InstructionExecutionDetector.swift Tests/InstructionExecutionDetectorTests.swift -o $(TEST_BUILD_DIR)/InstructionExecutionDetectorTests
	@$(TEST_BUILD_DIR)/InstructionExecutionDetectorTests
	@swiftc -parse-as-library Tests/ReleaseSDKCompatibilityTests.swift -o $(TEST_BUILD_DIR)/ReleaseSDKCompatibilityTests
	@$(TEST_BUILD_DIR)/ReleaseSDKCompatibilityTests
	@swiftc -parse-as-library Sources/AudioInputDevice.swift Tests/SystemAudioInputSelectionTests.swift -o $(TEST_BUILD_DIR)/SystemAudioInputSelectionTests
	@$(TEST_BUILD_DIR)/SystemAudioInputSelectionTests
	@swiftc -parse-as-library Tests/SystemAudioRecorderSourceTests.swift -o $(TEST_BUILD_DIR)/SystemAudioRecorderSourceTests
	@$(TEST_BUILD_DIR)/SystemAudioRecorderSourceTests
	@swiftc -parse-as-library Tests/SystemDefaultAndSystemAudioRecorderSourceTests.swift -o $(TEST_BUILD_DIR)/SystemDefaultAndSystemAudioRecorderSourceTests
	@$(TEST_BUILD_DIR)/SystemDefaultAndSystemAudioRecorderSourceTests
	@swiftc -parse-as-library "$(CURDIR)/Sources/CanonicalPCM16WAV.swift" "$(CURDIR)/Sources/AudioMixdownService.swift" "$(CURDIR)/Tests/AudioMixdownServiceTests.swift" -o $(TEST_BUILD_DIR)/AudioMixdownServiceTests
	@$(TEST_BUILD_DIR)/AudioMixdownServiceTests
	@swiftc -parse-as-library "$(CURDIR)/Sources/AudioImportConversionService.swift" "$(CURDIR)/Tests/AudioImportConversionServiceTests.swift" -o $(TEST_BUILD_DIR)/AudioImportConversionServiceTests
	@$(TEST_BUILD_DIR)/AudioImportConversionServiceTests
	@swiftc -parse-as-library Sources/AudioWaveformHeights.swift Tests/AudioWaveformHeightsTests.swift -o $(TEST_BUILD_DIR)/AudioWaveformHeightsTests
	@$(TEST_BUILD_DIR)/AudioWaveformHeightsTests
	@swiftc -parse-as-library Tests/SystemAudioAppStateRoutingTests.swift -o $(TEST_BUILD_DIR)/SystemAudioAppStateRoutingTests
	@$(TEST_BUILD_DIR)/SystemAudioAppStateRoutingTests
_test-transcription: $(SPARKLE_STAMP) $(LOCALIZATION_STAMP) $(FULL_SOURCE_TRANSCRIPTION_RUNNER) $(FULL_SOURCE_APP_STATE_RUNNER) | $(TEST_BUILD_DIR)
	@swiftc -parse-as-library Sources/RecordingJournalFailure.swift Sources/RecoveredRecordingContext.swift Sources/RecoveredRecordingMode.swift Sources/RecordingJournalModels.swift Sources/LocalizedStringLookup.swift Sources/AppName.swift Sources/CalendarIntegrationModels.swift Sources/QuillUserIssue.swift Sources/PipelineHistoryItem.swift Sources/TranscriptionModel.swift Sources/PipelineHistoryStore.swift Tests/PipelineHistoryCalendarMetadataTests.swift -o $(TEST_BUILD_DIR)/PipelineHistoryCalendarMetadataTests
	@$(TEST_BUILD_DIR)/PipelineHistoryCalendarMetadataTests
	@swiftc -parse-as-library Sources/CalendarIntegrationModels.swift Sources/GoogleCalendarTokenStore.swift Sources/GoogleCalendarAuthService.swift Sources/GoogleCalendarService.swift Tests/GoogleCalendarServiceTests.swift -o $(TEST_BUILD_DIR)/GoogleCalendarServiceTests
	@$(TEST_BUILD_DIR)/GoogleCalendarServiceTests
	@swiftc -parse-as-library Sources/LocalizedStringLookup.swift Sources/CalendarIntegrationModels.swift Sources/AppNotificationManager.swift Sources/CalendarRecordingReminderScheduler.swift Tests/CalendarRecordingReminderSchedulerTests.swift -o $(TEST_BUILD_DIR)/CalendarRecordingReminderSchedulerTests
	@$(TEST_BUILD_DIR)/CalendarRecordingReminderSchedulerTests
	@swiftc -parse-as-library Sources/LocalizedStringLookup.swift Sources/TranscriptionModel.swift Sources/SetupFlow.swift Tests/SetupFlowTests.swift -o $(TEST_BUILD_DIR)/SetupFlowTests
	@$(TEST_BUILD_DIR)/SetupFlowTests
	@swiftc -parse-as-library Sources/LocalizedStringLookup.swift Sources/TranscriptionModel.swift Tests/TranscriptionModelCacheTests.swift -o $(TEST_BUILD_DIR)/TranscriptionModelCacheTests
	@$(TEST_BUILD_DIR)/TranscriptionModelCacheTests
	@swiftc -parse-as-library Sources/LocalizedStringLookup.swift Sources/TranscriptionModel.swift Sources/AudioImportOptions.swift Tests/AudioImportOptionsTests.swift -o $(TEST_BUILD_DIR)/AudioImportOptionsTests
	@$(TEST_BUILD_DIR)/AudioImportOptionsTests
	@swiftc -parse-as-library Sources/LocalizedStringLookup.swift Sources/NativeWhisperModel.swift Tests/NativeWhisperModelTests.swift -o $(TEST_BUILD_DIR)/NativeWhisperModelTests
	@$(TEST_BUILD_DIR)/NativeWhisperModelTests
	@swiftc -parse-as-library Sources/LocalizedStringLookup.swift Sources/LocalAIModel.swift Tests/LocalAIModelTests.swift -o $(TEST_BUILD_DIR)/LocalAIModelTests
	@$(TEST_BUILD_DIR)/LocalAIModelTests
	@swiftc -parse-as-library Sources/LocalizedStringLookup.swift Sources/LocalAIModel.swift Tests/LocalAIModelStoreTests.swift -o $(TEST_BUILD_DIR)/LocalAIModelStoreTests
	@$(TEST_BUILD_DIR)/LocalAIModelStoreTests
	@swiftc -parse-as-library Sources/LocalizedStringLookup.swift Sources/LocalAIModel.swift Sources/LocalAIInstaller.swift Tests/LocalAIInstallerTests.swift -o $(TEST_BUILD_DIR)/LocalAIInstallerTests
	@$(TEST_BUILD_DIR)/LocalAIInstallerTests
	@swiftc -parse-as-library Sources/LocalAIServerProcess.swift Tests/LocalAIServerProcessTests.swift -o $(TEST_BUILD_DIR)/LocalAIServerProcessTests
	@$(TEST_BUILD_DIR)/LocalAIServerProcessTests
	@swiftc -parse-as-library Sources/LocalizedStringLookup.swift Sources/LocalAIModel.swift Sources/LocalAIServerProcess.swift Sources/LLMAPITransport.swift Sources/LocalAIServerManager.swift Tests/LocalAIServerManagerTests.swift -o $(TEST_BUILD_DIR)/LocalAIServerManagerTests
	@$(TEST_BUILD_DIR)/LocalAIServerManagerTests
	@swiftc -parse-as-library Sources/LocalizedStringLookup.swift Sources/QuillUserIssue.swift Sources/NativeWhisperModel.swift Sources/NativeWhisperRuntime.swift Tests/NativeWhisperRuntimeTests.swift -o $(TEST_BUILD_DIR)/NativeWhisperRuntimeTests
	@$(TEST_BUILD_DIR)/NativeWhisperRuntimeTests
	@swiftc -parse-as-library Sources/LocalizedStringLookup.swift Sources/NativeWhisperModel.swift Sources/NativeWhisperInstaller.swift Tests/NativeWhisperInstallerTests.swift -o $(TEST_BUILD_DIR)/NativeWhisperInstallerTests
	@$(TEST_BUILD_DIR)/NativeWhisperInstallerTests
	@swiftc -parse-as-library Sources/LLMCooldownManager.swift Tests/LLMCooldownManagerTests.swift -o $(TEST_BUILD_DIR)/LLMCooldownManagerTests
	@$(TEST_BUILD_DIR)/LLMCooldownManagerTests
	@swiftc -parse-as-library Sources/OverlayScreenGeometry.swift Tests/OverlayScreenGeometryTests.swift -o $(TEST_BUILD_DIR)/OverlayScreenGeometryTests
	@$(TEST_BUILD_DIR)/OverlayScreenGeometryTests
	@swiftc -parse-as-library Sources/OverlayScreenGeometry.swift Sources/FixedIntrinsicHostingView.swift Sources/ShortcutCore/ShortcutModels.swift Sources/AudioInputDevice.swift Sources/LocalizedStringLookup.swift Sources/OverlayDisplayCopy.swift Sources/RecordingOverlay.swift Tests/RecordingOverlayGeometryTests.swift -o $(TEST_BUILD_DIR)/RecordingOverlayGeometryTests
	@$(TEST_BUILD_DIR)/RecordingOverlayGeometryTests
	@swiftc -parse-as-library Tests/UpstreamMergeBehaviorTests.swift -o $(TEST_BUILD_DIR)/UpstreamMergeBehaviorTests
	@$(TEST_BUILD_DIR)/UpstreamMergeBehaviorTests
	@swiftc -parse-as-library Sources/LocalizedStringLookup.swift Sources/OverlayDisplayCopy.swift Sources/OverlayScreenGeometry.swift Sources/FixedIntrinsicHostingView.swift Sources/ShortcutCore/ShortcutModels.swift Sources/AudioInputDevice.swift Sources/RecordingOverlay.swift Sources/CalendarIntegrationModels.swift Sources/AppNotificationManager.swift Sources/CalendarRecordingReminderScheduler.swift Sources/MeetingReminderOverlay.swift Tests/MeetingReminderOverlayGeometryTests.swift -o $(TEST_BUILD_DIR)/MeetingReminderOverlayGeometryTests
	@$(TEST_BUILD_DIR)/MeetingReminderOverlayGeometryTests
	@swiftc -parse-as-library Sources/AppBuild.swift Tests/AppBuildTests.swift -o $(TEST_BUILD_DIR)/AppBuildTests
	@$(TEST_BUILD_DIR)/AppBuildTests
	@swiftc -parse-as-library Sources/CriticalDictationActivityState.swift Tests/CriticalDictationActivityStateTests.swift -o $(TEST_BUILD_DIR)/CriticalDictationActivityStateTests
	@$(TEST_BUILD_DIR)/CriticalDictationActivityStateTests
	@swiftc -parse-as-library Sources/RecordingJournalFailure.swift Sources/RecoveredRecordingContext.swift Sources/LocalizedStringLookup.swift Sources/RecoveredRecordingMode.swift Sources/RecordingJournalModels.swift Sources/CalendarIntegrationModels.swift Sources/QuillUserIssue.swift Sources/PipelineHistoryItem.swift Tests/TranscriptionRecoveryPlaceholderTests.swift -o $(TEST_BUILD_DIR)/TranscriptionRecoveryPlaceholderTests
	@$(TEST_BUILD_DIR)/TranscriptionRecoveryPlaceholderTests
	@swiftc -parse-as-library Sources/MCPLocalAccessPolicy.swift Tests/MCPLocalAccessPolicyTests.swift -o $(TEST_BUILD_DIR)/MCPLocalAccessPolicyTests
	@$(TEST_BUILD_DIR)/MCPLocalAccessPolicyTests
	@start="$$(date +%s)"; status=0; \
		$(FULL_SOURCE_TRANSCRIPTION_RUNNER) || status=$$?; \
		end="$$(date +%s)"; \
		printf '[timing] group=full-source-transcription seconds=%s status=%s\n' "$$((end - start))" "$$status"; \
		exit "$$status"
	@start="$$(date +%s)"; status=0; \
		isolated_home="$$(mktemp -d /tmp/quill-app-state-tests.XXXXXX)"; \
		test -n "$$isolated_home" || exit 1; \
		trap 'rm -rf "$$isolated_home"' EXIT; \
		mkdir -p "$$isolated_home/tmp"; \
		CFFIXED_USER_HOME="$$isolated_home" TMPDIR="$$isolated_home/tmp" $(FULL_SOURCE_APP_STATE_RUNNER) || status=$$?; \
		end="$$(date +%s)"; \
		printf '[timing] group=full-source-app-state seconds=%s status=%s\n' "$$((end - start))" "$$status"; \
		exit "$$status"

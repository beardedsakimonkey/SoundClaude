PROJECT := SoundClaude/SoundClaude.xcodeproj
SCHEME := SoundClaude
CONFIGURATION ?= Debug
DERIVED_DATA_PATH := SoundClaude/DerivedData
APP := $(DERIVED_DATA_PATH)/Build/Products/$(CONFIGURATION)/SoundClaude.app
LSP_RESULT_BUNDLE := $(DERIVED_DATA_PATH)/SourceKitLSP.xcresult

.DEFAULT_GOAL := run

.PHONY: build run lsp icon

build:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA_PATH) \
		build

run: build
	open "$(APP)"

lsp:
	xcode-build-server config \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		--build_root "$(abspath $(DERIVED_DATA_PATH))"
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA_PATH) \
		clean
	rm -rf "$(abspath $(LSP_RESULT_BUNDLE))"
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA_PATH) \
		-resultBundlePath $(LSP_RESULT_BUNDLE) \
		build

icon:
	sh scripts/generate-app-icon.sh
	$(MAKE) build
	touch "$(APP)"
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(abspath $(APP))"

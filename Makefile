PROJECT := SoundClaude/SoundClaude.xcodeproj
SCHEME := SoundClaude
CONFIGURATION ?= Debug
DERIVED_DATA_PATH := SoundClaude/DerivedData
APP := $(DERIVED_DATA_PATH)/Build/Products/$(CONFIGURATION)/SoundClaude.app

.DEFAULT_GOAL := run

.PHONY: build run

build:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA_PATH) \
		build

run: build
	open "$(APP)"

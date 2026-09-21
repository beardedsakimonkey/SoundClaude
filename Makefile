PROJECT := SoundClaude/SoundClaude.xcodeproj
SCHEME := SoundClaude
CONFIGURATION ?= Debug
DERIVED_DATA_PATH := SoundClaude/DerivedData
APP := $(DERIVED_DATA_PATH)/Build/Products/$(CONFIGURATION)/SoundClaude.app
LSP_RESULT_BUNDLE := $(DERIVED_DATA_PATH)/SourceKitLSP.xcresult

.DEFAULT_GOAL := run

.PHONY: build release run lsp icon test test-focus test-queue-drag

build:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA_PATH) \
		build

release:
	$(MAKE) run CONFIGURATION=Release

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

# Focus regression opens a temporary window and requires a macOS GUI session.
test-focus:
	@mkdir -p /tmp/soundclaude-tests
	swiftc -o /tmp/soundclaude-tests/search-focus \
		SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
		SoundClaude/SoundClaude/App/RecentSearchStore.swift \
		SoundClaude/SoundClaude/App/SearchView.swift \
		SoundClaude/SoundClaude/App/ScrollbarReservedScrollView.swift \
		SoundClaude/SoundClaude/App/RouteGradientBackdrop.swift \
		SoundClaude/SoundClaude/App/ContentHover.swift \
		SoundClaude/SoundClaude/Likes/SearchOutsideClickView.swift \
		tests/SearchFocusTests.swift
	/tmp/soundclaude-tests/search-focus

# Standalone regression suites; no credentials or Keychain access required.
test:
	@mkdir -p /tmp/soundclaude-tests
	swiftc -o /tmp/soundclaude-tests/artwork-cache \
		SoundClaude/SoundClaude/Support/MemoryCache.swift \
		SoundClaude/SoundClaude/Networking/ArtworkLoader.swift \
		tests/ArtworkCacheTests.swift
	/tmp/soundclaude-tests/artwork-cache
	swiftc -o /tmp/soundclaude-tests/reposts \
		SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
		SoundClaude/SoundClaude/Networking/SoundCloudClient.swift \
		SoundClaude/SoundClaude/App/RepostsController.swift \
		tests/RepostsTests.swift
	/tmp/soundclaude-tests/reposts
	@mkdir -p /tmp/soundclaude-tests
	swiftc -o /tmp/soundclaude-tests/comments \
		SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
		SoundClaude/SoundClaude/Networking/SoundCloudClient.swift \
		tests/CommentsTests.swift
	/tmp/soundclaude-tests/comments
	swiftc -o /tmp/soundclaude-tests/waveform-comment-index \
		SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
		SoundClaude/SoundClaude/App/WaveformCommentIndex.swift \
		tests/WaveformCommentIndexTests.swift
	/tmp/soundclaude-tests/waveform-comment-index
	swiftc -o /tmp/soundclaude-tests/playback \
		SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
		SoundClaude/SoundClaude/Playback/PlaybackController.swift \
		tests/PlaybackTests.swift
	/tmp/soundclaude-tests/playback
	swiftc -o /tmp/soundclaude-tests/auth-restore \
		SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
		SoundClaude/SoundClaude/Auth/AuthController.swift \
		SoundClaude/SoundClaude/Auth/OAuthCallbackServer.swift \
		tests/AuthRestoreTests.swift
	/tmp/soundclaude-tests/auth-restore
	swiftc -o /tmp/soundclaude-tests/search \
		SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
		SoundClaude/SoundClaude/Networking/SoundCloudClient.swift \
		SoundClaude/SoundClaude/Playback/TrackQueue.swift \
		tests/SearchTests.swift
	/tmp/soundclaude-tests/search
	swiftc -o /tmp/soundclaude-tests/recent-searches \
		SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
		SoundClaude/SoundClaude/App/RecentSearchStore.swift \
		tests/RecentSearchTests.swift
	/tmp/soundclaude-tests/recent-searches
	swiftc -o /tmp/soundclaude-tests/sidebar-selection \
		SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
		SoundClaude/SoundClaude/App/SidebarDestination.swift \
		tests/SidebarSelectionTests.swift
	/tmp/soundclaude-tests/sidebar-selection
	swiftc -o /tmp/soundclaude-tests/queue-likes \
		SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
		SoundClaude/SoundClaude/Playback/TrackQueue.swift \
		SoundClaude/SoundClaude/Likes/LikesCache.swift \
		SoundClaude/SoundClaude/Likes/LikesController.swift \
		tests/QueueAndLikesTests.swift
	/tmp/soundclaude-tests/queue-likes
	swiftc -o /tmp/soundclaude-tests/track-pages \
		SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
		tests/TrackPageDecodingTests.swift
	/tmp/soundclaude-tests/track-pages
	swiftc -o /tmp/soundclaude-tests/feed \
		SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
		SoundClaude/SoundClaude/Networking/SoundCloudClient.swift \
		SoundClaude/SoundClaude/Playback/TrackQueue.swift \
		tests/FeedTests.swift
	/tmp/soundclaude-tests/feed
	swiftc -o /tmp/soundclaude-tests/feed-cache \
		SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
		SoundClaude/SoundClaude/App/FeedCache.swift \
		SoundClaude/SoundClaude/App/FeedController.swift \
		tests/FeedCacheTests.swift
	/tmp/soundclaude-tests/feed-cache
	swiftc -o /tmp/soundclaude-tests/playlists \
		SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
		SoundClaude/SoundClaude/Networking/SoundCloudClient.swift \
		tests/PlaylistTests.swift
	/tmp/soundclaude-tests/playlists
	swiftc -o /tmp/soundclaude-tests/playlists-cache \
		SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
		SoundClaude/SoundClaude/App/PlaylistsCache.swift \
		SoundClaude/SoundClaude/App/PlaylistsController.swift \
		tests/PlaylistsCacheTests.swift
	/tmp/soundclaude-tests/playlists-cache
	swiftc -o /tmp/soundclaude-tests/following \
		SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
		SoundClaude/SoundClaude/Networking/SoundCloudClient.swift \
		tests/FollowingTests.swift
	/tmp/soundclaude-tests/following
	swiftc -o /tmp/soundclaude-tests/history \
		SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
		SoundClaude/SoundClaude/Networking/SoundCloudClient.swift \
		SoundClaude/SoundClaude/Playback/TrackQueue.swift \
		tests/HistoryTests.swift
	/tmp/soundclaude-tests/history

# Queue drag regression opens a temporary window and posts mouse events.
test-queue-drag:
	@mkdir -p /tmp/soundclaude-tests
	swiftc -o /tmp/soundclaude-tests/queue-drag \
		SoundClaude/SoundClaude/Playback/TrackQueue.swift \
		SoundClaude/SoundClaude/App/TrackQueueView.swift \
		SoundClaude/SoundClaude/App/TrackQueueDragDrop.swift \
		SoundClaude/SoundClaude/App/TrackPlaybackIndicator.swift \
		tests/QueueDragTests.swift
	/tmp/soundclaude-tests/queue-drag

PROJECT := SoundClaude/SoundClaude.xcodeproj
SCHEME := SoundClaude
CONFIGURATION ?= Release
DERIVED_DATA_PATH := SoundClaude/DerivedData
APP := $(DERIVED_DATA_PATH)/Build/Products/$(CONFIGURATION)/SoundClaude.app
BUNDLE_ID := com.tim.soundclaude.native
LSP_RESULT_BUNDLE := $(DERIVED_DATA_PATH)/SourceKitLSP.xcresult

.DEFAULT_GOAL := release

.PHONY: api build release debug quit-running run dist lsp test test-focus test-queue-drag test-navigation test-sidebar-resize test-playback-title test-now-playing test-detail-waveform test-detail-heading

api:
	@set -eu; \
		tmp=$$(mktemp ./api.yaml.XXXXXX); \
		trap 'rm -f "$$tmp"' EXIT HUP INT TERM; \
		curl --fail --show-error --location \
			https://raw.githubusercontent.com/soundcloud/api/master/openapi/api.yaml \
			--output "$$tmp"; \
		chmod 644 "$$tmp"; \
		mv "$$tmp" api.yaml

build:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA_PATH) \
		build

release:
	$(MAKE) run CONFIGURATION=Release

debug:
	$(MAKE) run CONFIGURATION=Debug

# `open` only activates an app that is already running, so the old process has
# to exit first. Quit with an Apple Event rather than a signal so that
# willTerminate fires and the playback session is saved.
quit-running:
	@for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do \
		[ -n "$$(lsappinfo find bundleid=$(BUNDLE_ID))" ] || exit 0; \
		osascript \
			-e 'if application id "$(BUNDLE_ID)" is running then' \
			-e 'ignoring application responses' \
			-e 'tell application id "$(BUNDLE_ID)" to quit' \
			-e 'end ignoring' \
			-e 'end if' || exit 1; \
		sleep 0.5; \
	done; \
	echo "$(BUNDLE_ID) did not quit after 10 seconds" >&2; \
	exit 1

run: build
	$(MAKE) quit-running
	open "$(APP)"

# Universal, ad-hoc-signed build for sharing. Ad-hoc keeps the developer
# certificate (and its email address) out of the shipped signature.
DIST_DERIVED_DATA_PATH := build/DerivedData
DIST_APP := $(DIST_DERIVED_DATA_PATH)/Build/Products/Release/SoundClaude.app
DIST_DMG := build/SoundClaude.dmg

.PHONY: dist-build dmg

dist-build:
	rm -rf "$(DIST_DERIVED_DATA_PATH)"
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Release \
		-derivedDataPath $(DIST_DERIVED_DATA_PATH) \
		ARCHS="arm64 x86_64" \
		ONLY_ACTIVE_ARCH=NO \
		CODE_SIGN_STYLE=Manual \
		CODE_SIGN_IDENTITY=- \
		DEVELOPMENT_TEAM= \
		build
	codesign --verify --deep --strict "$(DIST_APP)"

dist: dmg

dmg: dist-build
	sh scripts/create-dmg.sh "$(DIST_APP)" "$(DIST_DMG)"

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

# Focus regression opens a temporary window and requires a macOS GUI session.
SRC_focus := \
	SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
	SoundClaude/SoundClaude/App/RecentSearchStore.swift \
	SoundClaude/SoundClaude/App/SearchView.swift \
	SoundClaude/SoundClaude/App/CountedSectionHeader.swift \
	SoundClaude/SoundClaude/App/NavigationPageViewport.swift \
	SoundClaude/SoundClaude/App/SearchTextField.swift \
	SoundClaude/SoundClaude/App/ScrollbarReservedScrollView.swift \
	SoundClaude/SoundClaude/App/RouteGradientBackdrop.swift \
	SoundClaude/SoundClaude/App/ContentHover.swift \
	SoundClaude/SoundClaude/Likes/SearchOutsideClickView.swift \
	tests/SearchFocusTests.swift
test-focus:
	@mkdir -p /tmp/soundclaude-tests
	swiftc -o /tmp/soundclaude-tests/search-focus $(SRC_focus)
	/tmp/soundclaude-tests/search-focus

# Type-check the suites that `test` doesn't run (most need a GUI session), so
# stale stubs fail here instead of the next time someone runs the suite.
TYPECHECK_SUITES := \
	focus \
	piston_rendering \
	queue_drag \
	sidebar_resize \
	navigation \
	playback_title \
	detail_waveform \
	now_playing \
	detail_heading \
	detail_play_button \
	detail_like_button \
	detail_swap_buttons \
	track_waveform_navigation \
	waveform_comment_hover \
	playback_session \
	network_activity \
	memory_cache_inspection \
	queue_presentation \
	station_loading

.PHONY: test-typecheck $(addprefix typecheck-,$(TYPECHECK_SUITES))
test-typecheck: $(addprefix typecheck-,$(TYPECHECK_SUITES))
$(addprefix typecheck-,$(TYPECHECK_SUITES)): typecheck-%:
	swiftc -typecheck $(SRC_$*)

# Standalone regression suites; no credentials or Keychain access required.
test: test-typecheck test-playback-selection
	@mkdir -p /tmp/soundclaude-tests
	clang -c SoundClaude/SoundClaude/Audio/PCMRingBuffer.c -o /tmp/soundclaude-tests/pcm-ring.o
	swiftc -import-objc-header SoundClaude/SoundClaude/Audio/PCMRingBuffer.h \
		/tmp/soundclaude-tests/pcm-ring.o -framework CoreAudio -o /tmp/soundclaude-tests/spectrum \
		SoundClaude/SoundClaude/Audio/SpectrumAnalyzer.swift \
		tests/SpectrumAnalyzerTests.swift
	/tmp/soundclaude-tests/spectrum
	swiftc -o /tmp/soundclaude-tests/audio-tap-lifecycle \
		SoundClaude/SoundClaude/Audio/AudioTapController.swift \
		tests/AudioTapLifecycleTests.swift
	/tmp/soundclaude-tests/audio-tap-lifecycle
	swiftc -o /tmp/soundclaude-tests/artwork-cache \
		SoundClaude/SoundClaude/Support/MemoryCache.swift \
		SoundClaude/SoundClaude/Networking/ArtworkLoader.swift \
		tests/ArtworkCacheTests.swift
	/tmp/soundclaude-tests/artwork-cache
	swiftc -o /tmp/soundclaude-tests/request-cache \
		SoundClaude/SoundClaude/Support/MemoryCache.swift \
		SoundClaude/SoundClaude/Support/RequestCache.swift \
		tests/RequestCacheTests.swift
	/tmp/soundclaude-tests/request-cache
	swiftc -o /tmp/soundclaude-tests/reposts \
		tests/APITestSupport.swift \
		SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
		SoundClaude/SoundClaude/Networking/SoundCloudClient.swift \
		SoundClaude/SoundClaude/Support/ToggleSync.swift \
		SoundClaude/SoundClaude/App/RepostsController.swift \
		tests/RepostsTests.swift
	/tmp/soundclaude-tests/reposts
	@mkdir -p /tmp/soundclaude-tests
	swiftc -o /tmp/soundclaude-tests/comments \
		tests/APITestSupport.swift \
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
		SoundClaude/SoundClaude/App/LaunchMetrics.swift \
		SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
		SoundClaude/SoundClaude/Auth/AuthController.swift \
		tests/AuthRestoreTests.swift
	/tmp/soundclaude-tests/auth-restore
	swiftc -o /tmp/soundclaude-tests/search \
		tests/APITestSupport.swift \
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
		SoundClaude/SoundClaude/App/NavigationPageViewport.swift \
		tests/SidebarSelectionTests.swift
	/tmp/soundclaude-tests/sidebar-selection
	swiftc -o /tmp/soundclaude-tests/queue-likes \
		SoundClaude/SoundClaude/App/LaunchMetrics.swift \
		SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
		SoundClaude/SoundClaude/Playback/TrackQueue.swift \
		SoundClaude/SoundClaude/Likes/LikesCache.swift \
		SoundClaude/SoundClaude/Support/ToggleSync.swift \
		SoundClaude/SoundClaude/Likes/LikesController.swift \
		tests/QueueAndLikesTests.swift
	/tmp/soundclaude-tests/queue-likes
	swiftc -o /tmp/soundclaude-tests/track-pages \
		SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
		tests/TrackPageDecodingTests.swift
	/tmp/soundclaude-tests/track-pages
	swiftc -o /tmp/soundclaude-tests/feed \
		tests/APITestSupport.swift \
		SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
		SoundClaude/SoundClaude/Networking/SoundCloudClient.swift \
		SoundClaude/SoundClaude/Playback/TrackQueue.swift \
		tests/FeedTests.swift
	/tmp/soundclaude-tests/feed
	swiftc -o /tmp/soundclaude-tests/feed-cache \
		SoundClaude/SoundClaude/App/LaunchMetrics.swift \
		SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
		SoundClaude/SoundClaude/App/FeedCache.swift \
		SoundClaude/SoundClaude/App/FeedController.swift \
		tests/FeedCacheTests.swift
	/tmp/soundclaude-tests/feed-cache
	swiftc -o /tmp/soundclaude-tests/playlists \
		tests/APITestSupport.swift \
		SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
		SoundClaude/SoundClaude/Networking/SoundCloudClient.swift \
		tests/PlaylistTests.swift
	/tmp/soundclaude-tests/playlists
	swiftc -o /tmp/soundclaude-tests/playlists-cache \
		SoundClaude/SoundClaude/App/LaunchMetrics.swift \
		SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
		SoundClaude/SoundClaude/App/PlaylistsCache.swift \
		SoundClaude/SoundClaude/Support/ToggleSync.swift \
		SoundClaude/SoundClaude/App/PlaylistsController.swift \
		tests/PlaylistsCacheTests.swift
	/tmp/soundclaude-tests/playlists-cache
	swiftc -o /tmp/soundclaude-tests/following \
		tests/APITestSupport.swift \
		SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
		SoundClaude/SoundClaude/Networking/SoundCloudClient.swift \
		tests/FollowingTests.swift
	/tmp/soundclaude-tests/following
	swiftc -o /tmp/soundclaude-tests/website-api \
		tests/APITestSupport.swift \
		SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
		SoundClaude/SoundClaude/Networking/SoundCloudClient.swift \
		tests/WebsiteAPITests.swift
	/tmp/soundclaude-tests/website-api
	swiftc -o /tmp/soundclaude-tests/history \
		SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
		SoundClaude/SoundClaude/App/HistoryStore.swift \
		SoundClaude/SoundClaude/Networking/SoundCloudClient.swift \
		SoundClaude/SoundClaude/Playback/TrackQueue.swift \
		tests/HistoryTests.swift
	/tmp/soundclaude-tests/history

# Render rope glow against scene depth on a Metal GPU.
.PHONY: test-piston-rendering
SRC_piston_rendering := \
	-parse-as-library \
	tests/PistonRenderingTests.swift
test-piston-rendering:
	@mkdir -p /tmp/soundclaude-tests
	swiftc -o /tmp/soundclaude-tests/piston-rendering $(SRC_piston_rendering)
	/tmp/soundclaude-tests/piston-rendering

# Queue drag regression opens a temporary window and posts mouse events.
SRC_queue_drag := \
	SoundClaude/SoundClaude/Playback/TrackQueue.swift \
	SoundClaude/SoundClaude/App/TrackQueueView.swift \
	SoundClaude/SoundClaude/App/QueuePanel.swift \
	SoundClaude/SoundClaude/App/ContentHover.swift \
	SoundClaude/SoundClaude/App/EmptyStateView.swift \
	SoundClaude/SoundClaude/App/TrackQueueDragDrop.swift \
	SoundClaude/SoundClaude/App/TrackPlaybackIndicator.swift \
	tests/QueueDragTests.swift
test-queue-drag:
	@mkdir -p /tmp/soundclaude-tests
	swiftc -o /tmp/soundclaude-tests/queue-drag $(SRC_queue_drag)
	/tmp/soundclaude-tests/queue-drag

# Layout regression uses AppKit hosting and requires a macOS GUI session.
SRC_sidebar_resize := \
	SoundClaude/SoundClaude/App/NonCollapsingSidebar.swift \
	tests/SidebarResizeTests.swift
test-sidebar-resize:
	@mkdir -p /tmp/soundclaude-tests
	swiftc -o /tmp/soundclaude-tests/sidebar-resize $(SRC_sidebar_resize)
	/tmp/soundclaude-tests/sidebar-resize

SRC_navigation := \
	SoundClaude/SoundClaude/App/NavigationPageViewport.swift \
	tests/NavigationViewportTests.swift
test-navigation:
	@mkdir -p /tmp/soundclaude-tests
	swiftc -o /tmp/soundclaude-tests/navigation-viewport $(SRC_navigation)
	/tmp/soundclaude-tests/navigation-viewport

# Checks that selecting a track does not reflow its title on every animation frame.
SRC_playback_title := \
	SoundClaude/SoundClaude/App/TrackPlaybackIndicator.swift \
	tests/PlaybackTitleLayoutTests.swift
test-playback-title:
	@mkdir -p /tmp/soundclaude-tests
	swiftc -o /tmp/soundclaude-tests/playback-title $(SRC_playback_title)
	/tmp/soundclaude-tests/playback-title

# Keep the shared waveform mounted when detail routes change.
SRC_detail_waveform := \
	SoundClaude/SoundClaude/App/NavigationPageViewport.swift \
	SoundClaude/SoundClaude/App/DetailWaveformSlot.swift \
	SoundClaude/SoundClaude/App/DetailScrollForwarder.swift \
	tests/DetailWaveformLifetimeTests.swift
test-detail-waveform:
	@mkdir -p /tmp/soundclaude-tests
	swiftc -o /tmp/soundclaude-tests/detail-waveform $(SRC_detail_waveform)
	/tmp/soundclaude-tests/detail-waveform

# Keep Now Playing title changes out of the detail header's sizing.
SRC_now_playing := \
	SoundClaude/SoundClaude/App/FadeInOnAppear.swift \
	SoundClaude/SoundClaude/App/NowPlayingTrackRow.swift \
	SoundClaude/SoundClaude/App/RelativeTimestampView.swift \
	tests/NowPlayingLayoutTests.swift
test-now-playing:
	@mkdir -p /tmp/soundclaude-tests
	swiftc -o /tmp/soundclaude-tests/now-playing $(SRC_now_playing)
	/tmp/soundclaude-tests/now-playing

# Keep title and artist mounted across track/station navigation.
SRC_detail_heading := \
	SoundClaude/SoundClaude/App/NavigationPageViewport.swift \
	SoundClaude/SoundClaude/App/DetailTrackHeading.swift \
	SoundClaude/SoundClaude/App/TrackStationMenuItem.swift \
	SoundClaude/SoundClaude/App/DetailNavigationAnimation.swift \
	SoundClaude/SoundClaude/App/DetailScrollForwarder.swift \
	SoundClaude/SoundClaude/App/FadeInOnAppear.swift \
	SoundClaude/SoundClaude/App/RelativeTimestampView.swift \
	tests/DetailTrackHeadingTests.swift
test-detail-heading:
	@mkdir -p /tmp/soundclaude-tests
	swiftc -o /tmp/soundclaude-tests/detail-heading $(SRC_detail_heading)
	/tmp/soundclaude-tests/detail-heading

# Keep play controls mounted and update their behavior across detail routes.
.PHONY: test-detail-play-button
SRC_detail_play_button := \
	SoundClaude/SoundClaude/App/NavigationPageViewport.swift \
	SoundClaude/SoundClaude/App/DetailPlayButton.swift \
	SoundClaude/SoundClaude/App/DetailNavigationAnimation.swift \
	SoundClaude/SoundClaude/App/DetailScrollForwarder.swift \
	SoundClaude/SoundClaude/App/FadeInOnAppear.swift \
	tests/DetailPlayButtonTests.swift
test-detail-play-button:
	@mkdir -p /tmp/soundclaude-tests
	swiftc -o /tmp/soundclaude-tests/detail-play-button $(SRC_detail_play_button)
	/tmp/soundclaude-tests/detail-play-button

# Keep track likes mounted and route clicks to the current detail page.
.PHONY: test-detail-like-button
SRC_detail_like_button := \
	SoundClaude/SoundClaude/App/NavigationPageViewport.swift \
	SoundClaude/SoundClaude/App/DetailLikeButton.swift \
	SoundClaude/SoundClaude/App/DetailNavigationAnimation.swift \
	SoundClaude/SoundClaude/App/DetailScrollForwarder.swift \
	SoundClaude/SoundClaude/App/FadeInOnAppear.swift \
	tests/DetailLikeButtonTests.swift
test-detail-like-button:
	@mkdir -p /tmp/soundclaude-tests
	swiftc -o /tmp/soundclaude-tests/detail-like-button $(SRC_detail_like_button)
	/tmp/soundclaude-tests/detail-like-button

# Scale header buttons in and out when moving between a track and its collection.
.PHONY: test-detail-swap-buttons
SRC_detail_swap_buttons := \
	SoundClaude/SoundClaude/App/NavigationPageViewport.swift \
	SoundClaude/SoundClaude/App/DetailNavigationAnimation.swift \
	SoundClaude/SoundClaude/App/DetailScrollForwarder.swift \
	SoundClaude/SoundClaude/App/FadeInOnAppear.swift \
	tests/DetailSwapButtonTests.swift
test-detail-swap-buttons:
	@mkdir -p /tmp/soundclaude-tests
	swiftc -o /tmp/soundclaude-tests/detail-swap-buttons $(SRC_detail_swap_buttons)
	/tmp/soundclaude-tests/detail-swap-buttons

# Exercise real waveform loading and comment visibility across detail routes.
.PHONY: test-track-waveform-navigation
SRC_track_waveform_navigation := \
	SoundClaude/SoundClaude/App/NavigationPageViewport.swift \
	SoundClaude/SoundClaude/App/DetailWaveformSlot.swift \
	SoundClaude/SoundClaude/App/DetailScrollForwarder.swift \
	SoundClaude/SoundClaude/App/TrackWaveformView.swift \
	SoundClaude/SoundClaude/App/WaveformShadingCache.swift \
	SoundClaude/SoundClaude/App/ContentHover.swift \
	tests/TrackWaveformNavigationTests.swift
test-track-waveform-navigation:
	@mkdir -p /tmp/soundclaude-tests
	swiftc -o /tmp/soundclaude-tests/track-waveform-navigation $(SRC_track_waveform_navigation)
	/tmp/soundclaude-tests/track-waveform-navigation

# Exercise pointer travel from waveform avatars into comment bubbles and artist links.
.PHONY: test-waveform-comment-hover
SRC_waveform_comment_hover := \
	SoundClaude/SoundClaude/App/WaveformCommentsView.swift \
	SoundClaude/SoundClaude/App/DetailScrollForwarder.swift \
	SoundClaude/SoundClaude/App/WaveformCommentIndex.swift \
	SoundClaude/SoundClaude/App/ContentHover.swift \
	SoundClaude/SoundClaude/App/FadeInOnAppear.swift \
	tests/WaveformCommentHoverTests.swift
test-waveform-comment-hover:
	@mkdir -p /tmp/soundclaude-tests
	swiftc -o /tmp/soundclaude-tests/waveform-comment-hover $(SRC_waveform_comment_hover)
	/tmp/soundclaude-tests/waveform-comment-hover

.PHONY: test-playback-selection
SRC_playback_selection := \
	SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
	SoundClaude/SoundClaude/Playback/PlaybackController.swift \
	tests/PlaybackSelectionTests.swift
test-playback-selection:
	@mkdir -p /tmp/soundclaude-tests
	swiftc -o /tmp/soundclaude-tests/playback-selection $(SRC_playback_selection)
	/tmp/soundclaude-tests/playback-selection

# Session saves must not invalidate views that observe UI settings (requires GUI).
.PHONY: test-playback-session
SRC_playback_session := \
	SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
	SoundClaude/SoundClaude/Playback/PlaybackController.swift \
	SoundClaude/SoundClaude/Playback/TrackQueue.swift \
	tests/PlaybackSessionStorageTests.swift
test-playback-session:
	@mkdir -p /tmp/soundclaude-tests
	swiftc -o /tmp/soundclaude-tests/playback-session $(SRC_playback_session)
	/tmp/soundclaude-tests/playback-session

.PHONY: test-network-activity
SRC_network_activity := \
	-D DEBUG \
	SoundClaude/SoundClaude/App/NetworkActivity.swift \
	tests/NetworkActivityTests.swift
test-network-activity:
	@mkdir -p /tmp/soundclaude-tests
	swiftc -o /tmp/soundclaude-tests/network-activity $(SRC_network_activity)
	/tmp/soundclaude-tests/network-activity

.PHONY: test-memory-cache-inspection
SRC_memory_cache_inspection := \
	-D DEBUG \
	SoundClaude/SoundClaude/Support/MemoryCache.swift \
	tests/MemoryCacheInspectionTests.swift
test-memory-cache-inspection:
	@mkdir -p /tmp/soundclaude-tests
	swiftc -o /tmp/soundclaude-tests/memory-cache-inspection $(SRC_memory_cache_inspection)
	/tmp/soundclaude-tests/memory-cache-inspection

# Queue visibility must update the footer without reevaluating pages (requires GUI).
.PHONY: test-queue-presentation
SRC_queue_presentation := \
	SoundClaude/SoundClaude/App/QueuePanel.swift \
	SoundClaude/SoundClaude/App/ContentHover.swift \
	tests/QueuePresentationTests.swift
test-queue-presentation:
	@mkdir -p /tmp/soundclaude-tests
	swiftc -o /tmp/soundclaude-tests/queue-presentation $(SRC_queue_presentation)
	/tmp/soundclaude-tests/queue-presentation

# Start must stay enabled while station progress hands off to the cache (requires GUI).
.PHONY: test-station-loading
SRC_station_loading := \
	SoundClaude/SoundClaude/Models/SoundCloudModels.swift \
	SoundClaude/SoundClaude/Support/MemoryCache.swift \
	SoundClaude/SoundClaude/Playback/TrackQueue.swift \
	SoundClaude/SoundClaude/App/StationDetailView.swift \
	SoundClaude/SoundClaude/App/NavigationPageViewport.swift \
	tests/StationLoadingTests.swift
test-station-loading:
	@mkdir -p /tmp/soundclaude-tests
	swiftc -o /tmp/soundclaude-tests/station-loading $(SRC_station_loading)
	/tmp/soundclaude-tests/station-loading

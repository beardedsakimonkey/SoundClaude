import Foundation
import SwiftUI

struct TrackDetailView: View {
    let track: SoundCloudTrack
    let model: AppModel

    @State private var details: SoundCloudTrackDetails?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let details {
                detailsView(details)
            } else if isLoading {
                ProgressView("Loading track")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label(
                        "Could not load track",
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text(errorMessage ?? "An unknown error occurred.")
                } actions: {
                    Button("Try Again") {
                        Task { await load() }
                    }
                }
            }
        }
        .navigationTitle(details?.track.title ?? track.title)
        .task(id: track.urn) {
            await load()
        }
    }

    private func detailsView(_ details: SoundCloudTrackDetails) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 24) {
                    TrackArtworkView(
                        artworkURL: details.track.artworkURL,
                        loader: model.artworkLoader,
                        size: 180
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Text(details.track.title)
                            .font(.largeTitle.weight(.semibold))
                            .textSelection(.enabled)
                        Text(details.track.uploader)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        if let genre = nonempty(details.genre) {
                            Label(genre, systemImage: "music.note.list")
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            Task { await model.play(details.track) }
                        } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
                }

                HStack(spacing: 24) {
                    statistic(details.playbackCount, label: "plays")
                    statistic(details.favoritingsCount, label: "likes")
                    statistic(details.commentCount, label: "comments")
                }

                if details.track.waveformURL != nil {
                    TrackWaveformView(track: details.track, model: model)
                }

                Divider()

                Grid(
                    alignment: .leading,
                    horizontalSpacing: 20,
                    verticalSpacing: 10
                ) {
                    informationRow(
                        "Duration",
                        value: format(
                            milliseconds: details.track.durationMilliseconds
                        )
                    )
                    informationRow("Uploaded", value: details.createdAt)
                    informationRow("Genre", value: details.genre)
                    informationRow(
                        "Access",
                        value: details.track.access.rawValue.capitalized
                    )
                }

                if let description = nonempty(details.description) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Description")
                            .font(.headline)
                        Text(description)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    @ViewBuilder
    private func statistic(_ count: Int?, label: String) -> some View {
        if let count {
            Text("\(count.formatted()) \(label)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func informationRow(_ label: String, value: String?) -> some View {
        if let value = nonempty(value) {
            GridRow {
                Text(label)
                    .foregroundStyle(.secondary)
                Text(value)
                    .textSelection(.enabled)
            }
        }
    }

    private func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func format(milliseconds: Int) -> String {
        let totalSeconds = max(milliseconds, 0) / 1_000
        return String(
            format: "%d:%02d",
            totalSeconds / 60,
            totalSeconds % 60
        )
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            details = try await model.trackDetails(for: track)
        } catch {
            details = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

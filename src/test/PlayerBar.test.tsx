import { createRef } from "react";
import { render, waitFor } from "@testing-library/react";
import { PlayerBar } from "../components/PlayerBar";

const api = vi.hoisted(() => ({ getWaveform: vi.fn() }));

vi.mock("../api", () => api);

const track = {
  urn: "soundcloud:tracks:1",
  title: "Track with a waveform",
  uploader: "Artist",
  artworkUrl: null,
  waveformUrl: "https://wave.sndcdn.com/test_m.png",
  permalinkUrl: "https://soundcloud.com/artist/track",
  uploaderPermalinkUrl: "https://soundcloud.com/artist",
  durationMs: 60_000,
  access: "playable" as const,
};

const source = {
  url: "https://cf-hls-media.sndcdn.com/stream.m3u8?Policy=test",
  kind: "hls" as const,
  codec: "aac" as const,
  bitrateKbps: 160,
  isPreview: false,
};

describe("PlayerBar", () => {
  beforeEach(() => {
    api.getWaveform.mockResolvedValue({ height: 100, samples: [0, 25, 50, 100] });
  });

  it("loads and renders the active track waveform", async () => {
    const { container } = render(
      <PlayerBar
        audioRef={createRef<HTMLAudioElement>()}
        nowPlaying={{ track, source }}
        onEnded={vi.fn()}
        onOpenSoundCloud={vi.fn()}
        onPlaybackError={vi.fn()}
      />,
    );

    await waitFor(() => expect(api.getWaveform).toHaveBeenCalledWith(track.waveformUrl));
    await waitFor(() => expect(container.querySelector('svg[viewBox="0 0 4 32"]')).toBeInTheDocument());
  });
});

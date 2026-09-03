import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import App from "../App";

const api = vi.hoisted(() => ({
  getSession: vi.fn(),
  beginLogin: vi.fn(),
  signOut: vi.fn(),
  getLikedTracks: vi.fn(),
  resolvePlayback: vi.fn(),
  getWaveform: vi.fn(),
  openSoundCloudUrl: vi.fn(),
}));

vi.mock("../api", () => ({
  ...api,
  toCommandError: (value: unknown) =>
    typeof value === "object" && value !== null
      ? value
      : { code: "unexpected", message: String(value) },
}));

const user = {
  username: "listener",
  avatarUrl: null,
  permalinkUrl: "https://soundcloud.com/listener",
};

const track = {
  urn: "soundcloud:tracks:1",
  title: "A liked track",
  uploader: "Artist",
  artworkUrl: "https://i1.sndcdn.com/artworks-test-large.jpg",
  waveformUrl: null,
  permalinkUrl: "https://soundcloud.com/artist/track",
  uploaderPermalinkUrl: "https://soundcloud.com/artist",
  durationMs: 125_000,
  access: "playable" as const,
};

const nextTrack = {
  ...track,
  urn: "soundcloud:tracks:2",
  title: "The next liked track",
  permalinkUrl: "https://soundcloud.com/artist/next-track",
};

describe("App", () => {
  beforeEach(() => {
    api.getSession.mockResolvedValue({ authenticated: false, user: null });
    api.beginLogin.mockResolvedValue({ authenticated: true, user });
    api.getLikedTracks.mockResolvedValue([track]);
    api.resolvePlayback.mockResolvedValue({
      url: "https://cf-hls-media.sndcdn.com/stream.m3u8?Policy=test",
      kind: "hls",
      codec: "aac",
      bitrateKbps: 160,
      isPreview: false,
    });
    api.signOut.mockResolvedValue(undefined);
    api.openSoundCloudUrl.mockResolvedValue(undefined);
  });

  it("shows the sign-in action when no session exists", async () => {
    render(<App />);
    expect(await screen.findByRole("button", { name: "Sign in with SoundCloud" })).toBeVisible();
  });

  it("loads liked tracks for a restored session and resolves playback", async () => {
    api.getSession.mockResolvedValue({ authenticated: true, user });
    render(<App />);

    expect(await screen.findByText("A liked track")).toBeVisible();
    expect(screen.getByText("2:05")).toBeVisible();
    fireEvent.click(screen.getAllByRole("button", { name: "Play" })[0]);

    await waitFor(() => {
      expect(api.resolvePlayback).toHaveBeenCalledWith("soundcloud:tracks:1");
    });
    expect(await screen.findByText("Play again")).toBeVisible();
    expect(screen.getByText("AAC · 160 kbps")).toBeVisible();
    expect(screen.getByAltText("A liked track artwork")).toBeVisible();
    expect(screen.queryByText("Now playing")).not.toBeInTheDocument();
    const player = screen.getByLabelText("SoundCloud player");
    expect(player).not.toHaveAttribute("controls");

    fireEvent.play(player);
    expect(screen.getByRole("button", { name: "Pause" })).toBeVisible();

    fireEvent.change(screen.getByLabelText("Playback position"), { target: { value: "30" } });
    expect(screen.getByText("0:30")).toBeVisible();

    fireEvent.click(screen.getByRole("button", { name: "Pause" }));
    expect(HTMLMediaElement.prototype.pause).toHaveBeenCalled();
  });

  it("plays the next liked track when the current track ends", async () => {
    api.getSession.mockResolvedValue({ authenticated: true, user });
    api.getLikedTracks.mockResolvedValue([track, nextTrack]);
    render(<App />);

    fireEvent.click((await screen.findAllByRole("button", { name: "Play" }))[0]);
    await waitFor(() => {
      expect(api.resolvePlayback).toHaveBeenCalledWith(track.urn);
    });

    fireEvent.ended(screen.getByLabelText("SoundCloud player"));

    await waitFor(() => {
      expect(api.resolvePlayback).toHaveBeenCalledWith(nextTrack.urn);
    });
    expect(screen.getAllByText(nextTrack.title)).toHaveLength(2);
    expect(screen.getAllByRole("button", { name: "Play again" })).toHaveLength(1);
  });

  it("completes login and loads the library", async () => {
    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: "Sign in with SoundCloud" }));
    expect(await screen.findByText("A liked track")).toBeVisible();
    expect(api.beginLogin).toHaveBeenCalledOnce();
  });
});

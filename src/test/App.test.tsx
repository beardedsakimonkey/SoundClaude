import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import App from "../App";

const api = vi.hoisted(() => ({
  getSession: vi.fn(),
  beginLogin: vi.fn(),
  signOut: vi.fn(),
  getLikedTracks: vi.fn(),
  resolvePlayback: vi.fn(),
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
  artworkUrl: null,
  permalinkUrl: "https://soundcloud.com/artist/track",
  uploaderPermalinkUrl: "https://soundcloud.com/artist",
  durationMs: 125_000,
  access: "playable" as const,
};

describe("App", () => {
  beforeEach(() => {
    api.getSession.mockResolvedValue({ authenticated: false, user: null });
    api.beginLogin.mockResolvedValue({ authenticated: true, user });
    api.getLikedTracks.mockResolvedValue([track]);
    api.resolvePlayback.mockResolvedValue({
      url: "https://cf-hls-media.sndcdn.com/stream.m3u8?Policy=test",
      kind: "hls",
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
    fireEvent.click(screen.getByRole("button", { name: "Play" }));

    await waitFor(() => {
      expect(api.resolvePlayback).toHaveBeenCalledWith("soundcloud:tracks:1");
    });
    expect(await screen.findByText("Play again")).toBeVisible();
  });

  it("completes login and loads the library", async () => {
    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: "Sign in with SoundCloud" }));
    expect(await screen.findByText("A liked track")).toBeVisible();
    expect(api.beginLogin).toHaveBeenCalledOnce();
  });
});

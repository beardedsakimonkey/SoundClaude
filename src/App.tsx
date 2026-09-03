import { useCallback, useEffect, useRef, useState } from "react";
import * as stylex from "@stylexjs/stylex";
import {
  beginLogin,
  getLikedTracks,
  getSession,
  openSoundCloudUrl,
  resolvePlayback,
  signOut,
  toCommandError,
} from "./api";
import { AppHeader } from "./components/AppHeader";
import { AudioVisualizer } from "./components/AudioVisualizer";
import { ErrorNotice } from "./components/ErrorNotice";
import { KeyboardShortcutsDialog } from "./components/KeyboardShortcutsDialog";
import { LoginScreen } from "./components/LoginScreen";
import { NativeAudioProbeControl } from "./components/NativeAudioProbeControl";
import { PlayerBar } from "./components/PlayerBar";
import { TrackList } from "./components/TrackList";
import { usePlaybackHotkeys } from "./hooks/usePlaybackHotkeys";
import type {
  CommandError,
  PlaybackSource,
  SessionState,
  TrackSummary,
} from "./types";

const styles = stylex.create({
  centered: {
    minHeight: "100vh",
    display: "grid",
    placeItems: "center",
    padding: 32,
  },
  appShell: {
    minHeight: "100vh",
    paddingBottom: {
      default: 112,
      "@media (max-width: 700px)": 172,
    },
  },
  content: {
    maxWidth: 900,
    margin: "0 auto",
    padding: "26px 30px",
  },
  status: {
    color: {
      default: "#68686f",
      "@media (prefers-color-scheme: dark)": "#aaaab2",
    },
    textAlign: "center",
    padding: "60px 0",
  },
});

const SIGNED_OUT: SessionState = { authenticated: false, user: null };

export default function App() {
  const [session, setSession] = useState<SessionState | null>(null);
  const [tracks, setTracks] = useState<TrackSummary[]>([]);
  const [loadingTracks, setLoadingTracks] = useState(false);
  const [authenticating, setAuthenticating] = useState(false);
  const [error, setError] = useState<CommandError | null>(null);
  const [playbackError, setPlaybackError] = useState<CommandError | null>(null);
  const [resolvingUrn, setResolvingUrn] = useState<string | null>(null);
  const [nowPlaying, setNowPlaying] = useState<{
    track: TrackSummary;
    source: PlaybackSource;
  } | null>(null);
  const audioRef = useRef<HTMLAudioElement>(null);

  const handleAuthenticationFailure = useCallback((commandError: CommandError) => {
    if (commandError.code === "not_authenticated") {
      setSession(SIGNED_OUT);
      setTracks([]);
      setNowPlaying(null);
    }
    return commandError;
  }, []);

  const loadTracks = useCallback(async () => {
    setLoadingTracks(true);
    setError(null);
    try {
      setTracks(await getLikedTracks());
    } catch (value) {
      setError(handleAuthenticationFailure(toCommandError(value)));
    } finally {
      setLoadingTracks(false);
    }
  }, [handleAuthenticationFailure]);

  useEffect(() => {
    let active = true;
    void getSession()
      .then((nextSession) => {
        if (!active) return;
        setSession(nextSession);
        if (nextSession.authenticated) void loadTracks();
      })
      .catch((value) => {
        if (!active) return;
        setSession(SIGNED_OUT);
        setError(toCommandError(value));
      });
    return () => {
      active = false;
    };
  }, [loadTracks]);

  useEffect(() => {
    if (!nowPlaying || !audioRef.current) return;
    audioRef.current.load();
    void audioRef.current.play().catch(() => {
      // WebKit can require one more click on the player control.
    });
  }, [nowPlaying]);

  async function logIn() {
    setAuthenticating(true);
    setError(null);
    try {
      const nextSession = await beginLogin();
      setSession(nextSession);
      await loadTracks();
    } catch (value) {
      setError(toCommandError(value));
    } finally {
      setAuthenticating(false);
    }
  }

  async function logOut() {
    setError(null);
    try {
      await signOut();
    } catch (value) {
      setError(toCommandError(value));
    } finally {
      audioRef.current?.pause();
      setNowPlaying(null);
      setTracks([]);
      setSession(SIGNED_OUT);
    }
  }

  async function playTrack(track: TrackSummary) {
    setPlaybackError(null);
    if (nowPlaying?.track.urn === track.urn && audioRef.current) {
      void audioRef.current.play();
      return;
    }

    audioRef.current?.pause();
    setResolvingUrn(track.urn);
    try {
      const source = await resolvePlayback(track.urn);
      setNowPlaying({ track, source });
    } catch (value) {
      setPlaybackError(handleAuthenticationFailure(toCommandError(value)));
    } finally {
      setResolvingUrn(null);
    }
  }

  function playNextTrack() {
    if (!nowPlaying) return;

    const currentIndex = tracks.findIndex((track) => track.urn === nowPlaying.track.urn);
    if (currentIndex < 0) return;

    const nextTrack = tracks[currentIndex + 1];
    if (nextTrack) void playTrack(nextTrack);
  }

  function playPreviousTrack() {
    if (!nowPlaying) return;

    const currentIndex = tracks.findIndex((track) => track.urn === nowPlaying.track.urn);
    if (currentIndex <= 0) return;

    void playTrack(tracks[currentIndex - 1]);
  }

  function handlePlaybackError() {
    setPlaybackError({
      code: "playback_failed",
      message: "The audio stream could not be played. Select the track again to get a fresh stream.",
    });
  }

  const { closeShortcuts, shortcutsOpen } = usePlaybackHotkeys({
    audioRef,
    enabled: session?.authenticated === true,
    onNext: playNextTrack,
    onPlaybackError: handlePlaybackError,
    onPrevious: playPreviousTrack,
    playbackEnabled: nowPlaying !== null,
  });

  function openExternal(url: string) {
    void openSoundCloudUrl(url).catch((value) => setError(toCommandError(value)));
  }

  if (session === null) {
    return <main {...stylex.props(styles.centered)}><p>Loading SoundClaude…</p></main>;
  }

  if (!session.authenticated || !session.user) {
    return (
      <LoginScreen
        authenticating={authenticating}
        error={error}
        onLogIn={logIn}
      />
    );
  }

  return (
    <div {...stylex.props(styles.appShell)}>
      <AppHeader
        onOpenProfile={() => openExternal(session.user!.permalinkUrl)}
        onSignOut={logOut}
        user={session.user}
      />

      <AudioVisualizer
        active={nowPlaying !== null}
        audioRef={audioRef}
        durationMilliseconds={nowPlaying?.track.durationMs ?? 0}
        waveformUrl={nowPlaying?.track.waveformUrl ?? null}
      />
      <NativeAudioProbeControl
        audioRef={audioRef}
        trackUrn={nowPlaying?.track.urn ?? null}
      />

      <main {...stylex.props(styles.content)}>
        {error && <ErrorNotice error={error} onRetry={loadTracks} />}
        {loadingTracks ? (
          <p {...stylex.props(styles.status)}>Loading liked tracks…</p>
        ) : tracks.length === 0 && !error ? (
          <p {...stylex.props(styles.status)}>No playable liked tracks were found.</p>
        ) : (
          <TrackList
            nowPlayingUrn={nowPlaying?.track.urn ?? null}
            onOpen={openExternal}
            onPlay={playTrack}
            resolvingUrn={resolvingUrn}
            tracks={tracks}
          />
        )}

        {playbackError && <ErrorNotice error={playbackError} />}
      </main>

      <KeyboardShortcutsDialog onClose={closeShortcuts} open={shortcutsOpen} />

      <PlayerBar
        audioRef={audioRef}
        nowPlaying={nowPlaying}
        onEnded={playNextTrack}
        onPlaybackError={handlePlaybackError}
      />
    </div>
  );
}

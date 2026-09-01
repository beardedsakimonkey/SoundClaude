import type { RefObject } from "react";
import * as stylex from "@stylexjs/stylex";
import { POWERED_BY_SOUNDCLOUD } from "../assets";
import type { PlaybackSource, TrackSummary } from "../types";

const styles = stylex.create({
  bar: {
    position: "fixed",
    zIndex: 10,
    right: 0,
    bottom: 0,
    left: 0,
    display: "grid",
    gridTemplateColumns: "minmax(180px, 1fr) minmax(280px, 520px) minmax(180px, 1fr)",
    alignItems: "center",
    gap: 24,
    minHeight: 92,
    padding: "14px 34px",
    backgroundColor: {
      default: "rgb(255 255 255 / 96%)",
      "@media (prefers-color-scheme: dark)": "#222225",
    },
    borderTopColor: {
      default: "#d8d8dc",
      "@media (prefers-color-scheme: dark)": "#3a3a3f",
    },
    borderTopStyle: "solid",
    borderTopWidth: 1,
    backdropFilter: "blur(12px)",
  },
  nowPlaying: {
    minWidth: 0,
    display: "grid",
    gap: 5,
  },
  trackTitle: {
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
  eyebrow: {
    margin: 0,
    color: {
      default: "#77777e",
      "@media (prefers-color-scheme: dark)": "#aaaab2",
    },
    fontSize: 11,
    fontWeight: 750,
    letterSpacing: "0.12em",
    textTransform: "uppercase",
  },
  audio: {
    width: "100%",
  },
  logoButton: {
    justifySelf: "end",
    borderWidth: 0,
    padding: 0,
    backgroundColor: "transparent",
  },
  logo: {
    display: "block",
    width: 145,
    height: 29,
  },
});

interface PlayerBarProps {
  audioRef: RefObject<HTMLAudioElement | null>;
  nowPlaying: { track: TrackSummary; source: PlaybackSource } | null;
  onOpenSoundCloud: () => void;
  onPlaybackError: () => void;
}

export function PlayerBar({ audioRef, nowPlaying, onOpenSoundCloud, onPlaybackError }: PlayerBarProps) {
  return (
    <footer {...stylex.props(styles.bar)}>
      <div {...stylex.props(styles.nowPlaying)}>
        <span {...stylex.props(styles.eyebrow)}>Now playing</span>
        <strong {...stylex.props(styles.trackTitle)}>{nowPlaying?.track.title ?? "Choose a track"}</strong>
      </div>
      <audio
        {...stylex.props(styles.audio)}
        aria-label="SoundCloud player"
        controls
        onError={onPlaybackError}
        ref={audioRef}
        src={nowPlaying?.source.url}
      />
      <button {...stylex.props(styles.logoButton)} onClick={onOpenSoundCloud} type="button">
        <img {...stylex.props(styles.logo)} src={POWERED_BY_SOUNDCLOUD} alt="Powered by SoundCloud" />
      </button>
    </footer>
  );
}

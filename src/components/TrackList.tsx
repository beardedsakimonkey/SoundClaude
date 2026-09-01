import * as stylex from "@stylexjs/stylex";
import type { TrackSummary } from "../types";

const styles = stylex.create({
  list: {
    display: "grid",
    gap: 8,
    margin: 0,
    padding: 0,
    listStyle: "none",
  },
  track: {
    display: "grid",
    gridTemplateColumns: "58px minmax(0, 1fr) auto auto auto",
    alignItems: "center",
    gap: 14,
    minHeight: 74,
    padding: "8px 12px 8px 8px",
    backgroundColor: {
      default: "white",
      "@media (prefers-color-scheme: dark)": "#222225",
    },
    borderColor: {
      default: "#dedee2",
      "@media (prefers-color-scheme: dark)": "#3a3a3f",
    },
    borderStyle: "solid",
    borderWidth: 1,
    borderRadius: 11,
  },
  active: {
    borderColor: "#f50",
    boxShadow: "0 0 0 1px #f50",
  },
  artwork: {
    width: 58,
    height: 58,
    borderRadius: 7,
    objectFit: "cover",
  },
  artworkFallback: {
    display: "grid",
    placeItems: "center",
    backgroundColor: {
      default: "#e8e8eb",
      "@media (prefers-color-scheme: dark)": "#39393e",
    },
    color: {
      default: "#777",
      "@media (prefers-color-scheme: dark)": "#f5f5f7",
    },
    fontSize: 24,
  },
  copy: {
    minWidth: 0,
    display: "grid",
    gap: 5,
  },
  textButton: {
    overflow: "hidden",
    borderWidth: 0,
    padding: 0,
    backgroundColor: "transparent",
    textAlign: "left",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
    textDecoration: {
      default: "none",
      ":hover": "underline",
    },
  },
  title: {
    color: "inherit",
    fontWeight: 650,
  },
  uploader: {
    color: {
      default: "#6e6e75",
      "@media (prefers-color-scheme: dark)": "#aaaab2",
    },
    fontSize: 13,
  },
  duration: {
    color: {
      default: "#77777e",
      "@media (prefers-color-scheme: dark)": "#aaaab2",
    },
    fontSize: 13,
    fontVariantNumeric: "tabular-nums",
  },
  previewBadge: {
    padding: "3px 6px",
    borderRadius: 4,
    backgroundColor: "#fff1e9",
    color: "#b33c00",
    fontSize: 11,
    fontWeight: 700,
    textTransform: "uppercase",
  },
  playButton: {
    minWidth: 84,
    padding: "9px 12px",
    borderWidth: 0,
    borderRadius: 8,
    backgroundColor: {
      default: "#1d1d1f",
      "@media (prefers-color-scheme: dark)": "#f5f5f7",
    },
    color: {
      default: "white",
      "@media (prefers-color-scheme: dark)": "#1d1d1f",
    },
    fontWeight: 650,
  },
});

interface TrackListProps {
  tracks: TrackSummary[];
  nowPlayingUrn: string | null;
  resolvingUrn: string | null;
  onOpen: (url: string) => void;
  onPlay: (track: TrackSummary) => void;
}

function durationLabel(durationMs: number): string {
  const seconds = Math.max(0, Math.floor(durationMs / 1000));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

export function TrackList({ tracks, nowPlayingUrn, resolvingUrn, onOpen, onPlay }: TrackListProps) {
  return (
    <ol {...stylex.props(styles.list)}>
      {tracks.map((track) => {
        const isPlaying = nowPlayingUrn === track.urn;

        return (
          <li {...stylex.props(styles.track, isPlaying && styles.active)} key={track.urn}>
            {track.artworkUrl ? (
              <img {...stylex.props(styles.artwork)} src={track.artworkUrl} alt="" loading="lazy" />
            ) : (
              <div {...stylex.props(styles.artwork, styles.artworkFallback)} aria-hidden="true">♪</div>
            )}
            <div {...stylex.props(styles.copy)}>
              <button {...stylex.props(styles.textButton, styles.title)} onClick={() => onOpen(track.permalinkUrl)} type="button">
                {track.title}
              </button>
              <button {...stylex.props(styles.textButton, styles.uploader)} onClick={() => onOpen(track.uploaderPermalinkUrl)} type="button">
                {track.uploader}
              </button>
            </div>
            <span {...stylex.props(styles.duration)}>{durationLabel(track.durationMs)}</span>
            {track.access === "preview" && <span {...stylex.props(styles.previewBadge)}>Preview</span>}
            <button
              {...stylex.props(styles.playButton)}
              disabled={resolvingUrn !== null}
              onClick={() => onPlay(track)}
              type="button"
            >
              {resolvingUrn === track.urn ? "Loading…" : isPlaying ? "Play again" : "Play"}
            </button>
          </li>
        );
      })}
    </ol>
  );
}

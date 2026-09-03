import { useEffect, useId, useMemo, useState } from "react";
import type { ChangeEvent, RefObject } from "react";
import * as stylex from "@stylexjs/stylex";
import { POWERED_BY_SOUNDCLOUD } from "../assets";
import { getWaveform } from "../api";
import type { PlaybackSource, TrackSummary } from "../types";

const styles = stylex.create({
  bar: {
    position: "fixed",
    zIndex: 10,
    right: 0,
    bottom: 0,
    left: 0,
    display: "grid",
    gridTemplateColumns: {
      default: "minmax(230px, 1fr) minmax(320px, 560px) minmax(220px, 1fr)",
      "@media (max-width: 700px)": "minmax(0, 1fr) auto",
    },
    alignItems: "center",
    columnGap: {
      default: 24,
      "@media (max-width: 900px)": 16,
    },
    rowGap: 10,
    minHeight: 92,
    padding: {
      default: "14px 34px",
      "@media (max-width: 900px)": "12px 20px",
      "@media (max-width: 700px)": "10px 16px 12px",
    },
    backgroundColor: {
      default: "rgb(255 255 255 / 96%)",
      "@media (prefers-color-scheme: dark)": "rgb(34 34 37 / 96%)",
    },
    borderTopColor: {
      default: "#d8d8dc",
      "@media (prefers-color-scheme: dark)": "#3a3a3f",
    },
    borderTopStyle: "solid",
    borderTopWidth: 1,
    boxShadow: {
      default: "0 -8px 28px rgb(20 20 24 / 6%)",
      "@media (prefers-color-scheme: dark)": "0 -8px 28px rgb(0 0 0 / 18%)",
    },
    backdropFilter: "blur(12px)",
  },
  track: {
    minWidth: 0,
    display: "grid",
    gridTemplateColumns: {
      default: "64px minmax(0, 1fr)",
      "@media (max-width: 700px)": "52px minmax(0, 1fr)",
    },
    alignItems: "center",
    gap: {
      default: 14,
      "@media (max-width: 700px)": 11,
    },
  },
  artwork: {
    display: "block",
    width: {
      default: 64,
      "@media (max-width: 700px)": 52,
    },
    height: {
      default: 64,
      "@media (max-width: 700px)": 52,
    },
    borderRadius: 8,
    objectFit: "cover",
    boxShadow: "0 2px 8px rgb(0 0 0 / 14%)",
  },
  artworkFallback: {
    display: "grid",
    placeItems: "center",
    backgroundColor: {
      default: "#e8e8eb",
      "@media (prefers-color-scheme: dark)": "#39393e",
    },
    color: {
      default: "#77777e",
      "@media (prefers-color-scheme: dark)": "#d4d4d8",
    },
    fontSize: 24,
  },
  trackCopy: {
    minWidth: 0,
    display: "grid",
    gap: 4,
  },
  trackTitle: {
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
    fontSize: 14,
    lineHeight: 1.25,
  },
  uploader: {
    overflow: "hidden",
    color: {
      default: "#68686f",
      "@media (prefers-color-scheme: dark)": "#b7b7bf",
    },
    fontSize: 12,
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
  streamDetails: {
    overflow: "hidden",
    color: {
      default: "#85858c",
      "@media (prefers-color-scheme: dark)": "#92929b",
    },
    fontSize: 10,
    fontWeight: 650,
    letterSpacing: "0.04em",
    textOverflow: "ellipsis",
    textTransform: "uppercase",
    whiteSpace: "nowrap",
  },
  transport: {
    minWidth: 0,
    display: "grid",
    gridTemplateColumns: "44px minmax(0, 1fr)",
    alignItems: "center",
    gap: 14,
    gridColumn: {
      default: "auto",
      "@media (max-width: 700px)": "1 / -1",
    },
  },
  playButton: {
    display: "grid",
    placeItems: "center",
    width: 44,
    height: 44,
    padding: 0,
    borderWidth: 0,
    borderRadius: "50%",
    backgroundColor: {
      default: "#1d1d1f",
      ":hover": "#f50",
      "@media (prefers-color-scheme: dark)": "#f5f5f7",
    },
    color: {
      default: "white",
      "@media (prefers-color-scheme: dark)": "#1d1d1f",
    },
    transitionDuration: "150ms",
    transitionProperty: "background-color, transform",
    transform: {
      default: "scale(1)",
      ":active": "scale(0.96)",
    },
  },
  timeline: {
    minWidth: 0,
    display: "grid",
    gap: 6,
  },
  waveformControl: {
    position: "relative",
    width: "100%",
    height: 34,
    borderRadius: 4,
    outline: {
      default: "none",
      ":focus-within": "2px solid #f50",
    },
    outlineOffset: 2,
  },
  waveform: {
    display: "block",
    width: "100%",
    height: "100%",
    overflow: "visible",
  },
  waveformPending: {
    color: {
      default: "#d4d4d8",
      "@media (prefers-color-scheme: dark)": "#52525a",
    },
  },
  waveformReady: {
    color: {
      default: "#a8a8af",
      "@media (prefers-color-scheme: dark)": "#686870",
    },
  },
  waveformPlayed: {
    color: "#f50",
  },
  seekInput: {
    position: "absolute",
    inset: 0,
    width: "100%",
    height: "100%",
    margin: 0,
    opacity: 0,
    cursor: "pointer",
  },
  timeRow: {
    display: "flex",
    justifyContent: "space-between",
    color: {
      default: "#77777e",
      "@media (prefers-color-scheme: dark)": "#aaaab2",
    },
    fontSize: 11,
    fontVariantNumeric: "tabular-nums",
  },
  rightSide: {
    display: "flex",
    alignItems: "center",
    justifyContent: "flex-end",
    gap: 18,
  },
  volume: {
    display: {
      default: "flex",
      "@media (max-width: 900px)": "none",
    },
    alignItems: "center",
    gap: 7,
  },
  iconButton: {
    display: "grid",
    placeItems: "center",
    width: 30,
    height: 30,
    padding: 0,
    borderWidth: 0,
    borderRadius: "50%",
    backgroundColor: {
      default: "transparent",
      ":hover": "#ececef",
      "@media (prefers-color-scheme: dark)": "transparent",
    },
    color: "inherit",
  },
  volumeInput: {
    width: 72,
    height: 4,
    margin: 0,
    accentColor: "#f50",
    cursor: "pointer",
  },
  logoButton: {
    flexShrink: 0,
    borderWidth: 0,
    borderRadius: 4,
    padding: "3px 4px",
    backgroundColor: "white",
  },
  logo: {
    display: "block",
    width: {
      default: 130,
      "@media (max-width: 700px)": 110,
    },
    height: "auto",
  },
  audioEngine: {
    display: "none",
  },
});

interface PlayerBarProps {
  audioRef: RefObject<HTMLAudioElement | null>;
  nowPlaying: { track: TrackSummary; source: PlaybackSource } | null;
  onEnded: () => void;
  onOpenSoundCloud: () => void;
  onPlaybackError: () => void;
}

const MAX_WAVEFORM_BARS = 180;
const EMPTY_WAVEFORM = Array.from({ length: 90 }, () => 0.04);

function prepareWaveform(payload: { height: number; samples: number[] }): number[] {
  if (!Array.isArray(payload.samples) || payload.samples.length === 0) return [];

  const samples = payload.samples.map((sample) =>
    typeof sample === "number" && Number.isFinite(sample) ? Math.max(sample, 0) : 0,
  );
  const payloadHeight = typeof payload.height === "number"
    && Number.isFinite(payload.height)
    && payload.height > 0
    ? payload.height
    : 0;
  let largestSample = 1;
  for (const sample of samples) largestSample = Math.max(largestSample, sample);
  const scale = Math.max(payloadHeight, largestSample);
  const barCount = Math.min(samples.length, MAX_WAVEFORM_BARS);
  const bars: number[] = [];

  for (let bar = 0; bar < barCount; bar += 1) {
    const start = Math.floor((bar * samples.length) / barCount);
    const end = Math.max(start + 1, Math.floor(((bar + 1) * samples.length) / barCount));
    let peak = 0;
    for (let index = start; index < end; index += 1) {
      peak = Math.max(peak, samples[index] ?? 0);
    }
    bars.push(Math.min(peak / scale, 1));
  }

  return bars;
}

function waveformPath(samples: number[]): string {
  return samples.map((sample, index) => {
    const halfHeight = Math.max(1.25, sample * 14);
    const x = index + 0.5;
    return `M${x} ${16 - halfHeight}V${16 + halfHeight}`;
  }).join(" ");
}

function timeLabel(timeSeconds: number): string {
  if (!Number.isFinite(timeSeconds) || timeSeconds < 0) return "0:00";
  const seconds = Math.floor(timeSeconds);
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

function PlayIcon() {
  return (
    <svg aria-hidden="true" height="20" viewBox="0 0 24 24" width="20">
      <path d="M8 5.5v13l10-6.5z" fill="currentColor" />
    </svg>
  );
}

function PauseIcon() {
  return (
    <svg aria-hidden="true" height="20" viewBox="0 0 24 24" width="20">
      <path d="M7 5h4v14H7zm6 0h4v14h-4z" fill="currentColor" />
    </svg>
  );
}

function VolumeIcon({ muted }: { muted: boolean }) {
  return (
    <svg aria-hidden="true" height="18" viewBox="0 0 24 24" width="18">
      <path d="M4 9v6h4l5 4V5L8 9zm11.5.3v5.4c.9-.7 1.5-1.6 1.5-2.7s-.6-2-1.5-2.7z" fill="currentColor" />
      {muted ? (
        <path d="m17.2 9.2 4.6 4.6m0-4.6-4.6 4.6" fill="none" stroke="currentColor" strokeLinecap="round" strokeWidth="1.8" />
      ) : (
        <path d="M18 7.7a6 6 0 0 1 0 8.6" fill="none" stroke="currentColor" strokeLinecap="round" strokeWidth="1.8" />
      )}
    </svg>
  );
}

export function PlayerBar({ audioRef, nowPlaying, onEnded, onOpenSoundCloud, onPlaybackError }: PlayerBarProps) {
  const [isPlaying, setIsPlaying] = useState(false);
  const [currentTime, setCurrentTime] = useState(0);
  const [duration, setDuration] = useState(0);
  const [volume, setVolume] = useState(1);
  const [muted, setMuted] = useState(false);
  const [artworkFailed, setArtworkFailed] = useState(false);
  const [waveformSamples, setWaveformSamples] = useState<number[]>([]);
  const waveformClipId = useId().replaceAll(":", "");

  useEffect(() => {
    setIsPlaying(false);
    setCurrentTime(0);
    setDuration((nowPlaying?.track.durationMs ?? 0) / 1000);
    setArtworkFailed(false);
  }, [nowPlaying?.track.urn]);

  useEffect(() => {
    const waveformUrl = nowPlaying?.track.waveformUrl;
    setWaveformSamples([]);
    if (!waveformUrl) return;

    let active = true;
    void getWaveform(waveformUrl)
      .then((payload) => {
        if (active) setWaveformSamples(prepareWaveform(payload));
      })
      .catch(() => {
        if (active) setWaveformSamples([]);
      });

    return () => {
      active = false;
    };
  }, [nowPlaying?.track.waveformUrl]);

  function updateDuration(audio: HTMLAudioElement) {
    if (Number.isFinite(audio.duration) && audio.duration > 0) {
      setDuration(audio.duration);
    }
  }

  function togglePlayback() {
    const audio = audioRef.current;
    if (!audio || !nowPlaying) return;

    if (isPlaying) {
      audio.pause();
      setIsPlaying(false);
      return;
    }

    setIsPlaying(true);
    void audio.play().catch(() => {
      setIsPlaying(false);
      onPlaybackError();
    });
  }

  function seek(event: ChangeEvent<HTMLInputElement>) {
    const nextTime = Number(event.currentTarget.value);
    if (!audioRef.current) return;
    audioRef.current.currentTime = nextTime;
    setCurrentTime(nextTime);
  }

  function changeVolume(event: ChangeEvent<HTMLInputElement>) {
    const nextVolume = Number(event.currentTarget.value);
    if (!audioRef.current) return;
    audioRef.current.volume = nextVolume;
    audioRef.current.muted = false;
    setVolume(nextVolume);
    setMuted(false);
  }

  function toggleMute() {
    if (!audioRef.current) return;
    const nextMuted = !audioRef.current.muted;
    audioRef.current.muted = nextMuted;
    setMuted(nextMuted);
  }

  const artworkUrl = nowPlaying?.track.artworkUrl;
  const displayDuration = duration || (nowPlaying?.track.durationMs ?? 0) / 1000;
  const seekMaximum = Math.max(displayDuration, 1);
  const seekValue = Math.min(currentTime, seekMaximum);
  const visibleWaveform = waveformSamples.length > 0 ? waveformSamples : EMPTY_WAVEFORM;
  const waveformData = useMemo(() => waveformPath(visibleWaveform), [visibleWaveform]);
  const waveformProgress = seekValue / seekMaximum;

  return (
    <footer {...stylex.props(styles.bar)}>
      <div {...stylex.props(styles.track)}>
        {artworkUrl && !artworkFailed ? (
          <img
            {...stylex.props(styles.artwork)}
            alt={`${nowPlaying.track.title} artwork`}
            onError={() => setArtworkFailed(true)}
            src={artworkUrl}
          />
        ) : (
          <div {...stylex.props(styles.artwork, styles.artworkFallback)} aria-hidden="true">♪</div>
        )}
        <div {...stylex.props(styles.trackCopy)}>
          <strong {...stylex.props(styles.trackTitle)}>{nowPlaying?.track.title ?? "Choose a track"}</strong>
          <span {...stylex.props(styles.uploader)}>{nowPlaying?.track.uploader ?? "Select a track to start listening"}</span>
          {nowPlaying && (
            <span {...stylex.props(styles.streamDetails)}>
              {nowPlaying.source.codec.toUpperCase()} · {nowPlaying.source.bitrateKbps} kbps
              {nowPlaying.source.isPreview ? " · Preview" : ""}
            </span>
          )}
        </div>
      </div>

      <div {...stylex.props(styles.transport)}>
        <button
          {...stylex.props(styles.playButton)}
          aria-label={isPlaying ? "Pause" : "Play"}
          disabled={!nowPlaying}
          onClick={togglePlayback}
          type="button"
        >
          {isPlaying ? <PauseIcon /> : <PlayIcon />}
        </button>
        <div {...stylex.props(styles.timeline)}>
          <div {...stylex.props(styles.waveformControl)}>
            <svg
              {...stylex.props(
                styles.waveform,
                waveformSamples.length > 0 ? styles.waveformReady : styles.waveformPending,
              )}
              aria-hidden="true"
              preserveAspectRatio="none"
              viewBox={`0 0 ${visibleWaveform.length} 32`}
            >
              <defs>
                <clipPath id={waveformClipId}>
                  <rect height="32" width={waveformProgress * visibleWaveform.length} />
                </clipPath>
              </defs>
              <path d={waveformData} fill="none" stroke="currentColor" strokeWidth="0.65" />
              <path
                {...stylex.props(styles.waveformPlayed)}
                clipPath={`url(#${waveformClipId})`}
                d={waveformData}
                fill="none"
                stroke="currentColor"
                strokeWidth="0.65"
              />
            </svg>
            <input
              {...stylex.props(styles.seekInput)}
              aria-label="Playback position"
              aria-valuetext={`${timeLabel(currentTime)} of ${timeLabel(displayDuration)}`}
              disabled={!nowPlaying}
              max={seekMaximum}
              min="0"
              onChange={seek}
              step="0.1"
              type="range"
              value={seekValue}
            />
          </div>
          <div {...stylex.props(styles.timeRow)}>
            <span>{timeLabel(currentTime)}</span>
            <span>{timeLabel(displayDuration)}</span>
          </div>
        </div>
      </div>

      <div {...stylex.props(styles.rightSide)}>
        <div {...stylex.props(styles.volume)}>
          <button
            {...stylex.props(styles.iconButton)}
            aria-label={muted ? "Unmute" : "Mute"}
            disabled={!nowPlaying}
            onClick={toggleMute}
            type="button"
          >
            <VolumeIcon muted={muted || volume === 0} />
          </button>
          <input
            {...stylex.props(styles.volumeInput)}
            aria-label="Volume"
            disabled={!nowPlaying}
            max="1"
            min="0"
            onChange={changeVolume}
            step="0.05"
            type="range"
            value={volume}
          />
        </div>
        <button {...stylex.props(styles.logoButton)} onClick={onOpenSoundCloud} type="button">
          <img {...stylex.props(styles.logo)} src={POWERED_BY_SOUNDCLOUD} alt="Powered by SoundCloud" />
        </button>
      </div>

      <audio
        {...stylex.props(styles.audioEngine)}
        aria-label="SoundCloud player"
        onDurationChange={(event) => updateDuration(event.currentTarget)}
        onEnded={() => {
          setIsPlaying(false);
          onEnded();
        }}
        onError={onPlaybackError}
        onLoadedMetadata={(event) => updateDuration(event.currentTarget)}
        onPause={() => setIsPlaying(false)}
        onPlay={() => setIsPlaying(true)}
        onTimeUpdate={(event) => setCurrentTime(event.currentTarget.currentTime)}
        onVolumeChange={(event) => {
          setVolume(event.currentTarget.volume);
          setMuted(event.currentTarget.muted);
        }}
        preload="metadata"
        ref={audioRef}
        src={nowPlaying?.source.url}
      />
    </footer>
  );
}

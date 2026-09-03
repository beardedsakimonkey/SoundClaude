import { useEffect, useRef, useState } from "react";
import type { RefObject } from "react";
import * as stylex from "@stylexjs/stylex";
import { startNativeAudioProbe, stopNativeAudioProbe, toCommandError } from "../api";
import { onNativeAudioProbeEvent } from "../nativeAudioProbe";

const styles = stylex.create({
  row: {
    alignItems: "center",
    display: "flex",
    gap: 10,
    justifyContent: "center",
    marginTop: 10,
    minHeight: 28,
  },
  button: {
    appearance: "none",
    backgroundColor: {
      default: "#fff",
      ":hover": "#f4f4f6",
      "@media (prefers-color-scheme: dark)": "#26262a",
    },
    borderColor: {
      default: "#d7d7dc",
      "@media (prefers-color-scheme: dark)": "#48484f",
    },
    borderRadius: 999,
    borderStyle: "solid",
    borderWidth: 1,
    color: {
      default: "#34343a",
      "@media (prefers-color-scheme: dark)": "#ededf0",
    },
    cursor: "pointer",
    fontSize: 12,
    fontWeight: 600,
    padding: "5px 11px",
  },
  disabled: {
    cursor: "default",
    opacity: 0.5,
  },
  status: {
    color: {
      default: "#68686f",
      "@media (prefers-color-scheme: dark)": "#aaaab2",
    },
    fontSize: 12,
  },
});

interface NativeAudioProbeControlProps {
  audioRef: RefObject<HTMLAudioElement | null>;
  trackUrn: string | null;
}

export function NativeAudioProbeControl({
  audioRef,
  trackUrn,
}: NativeAudioProbeControlProps) {
  const [running, setRunning] = useState(false);
  const [starting, setStarting] = useState(false);
  const [status, setStatus] = useState("Native PCM proof");
  const resumeWebPlayerRef = useRef(false);

  useEffect(() => {
    let current = true;
    let unlisten: (() => void) | undefined;

    void onNativeAudioProbeEvent((event) => {
      if (!current) return;
      if (event.type === "spectrum") {
        setStatus(`PCM RMS ${event.rms.toFixed(4)}`);
      } else if (event.type === "format") {
        setStatus(`${Math.round(event.sampleRate / 1000)} kHz · ${event.channels} ch`);
      } else if (event.type === "error") {
        setStatus(event.message);
        setRunning(false);
      }
    }).then((dispose) => {
      if (current) unlisten = dispose;
      else dispose();
    });

    return () => {
      current = false;
      unlisten?.();
      void stopNativeAudioProbe();
    };
  }, []);

  async function start() {
    if (!trackUrn || starting) return;
    setStarting(true);
    setStatus("Starting native player…");
    const audio = audioRef.current;
    resumeWebPlayerRef.current = audio ? !audio.paused : false;
    audio?.pause();

    try {
      await startNativeAudioProbe(trackUrn);
      audio?.pause();
      setRunning(true);
    } catch (value) {
      setStatus(toCommandError(value).message);
      if (resumeWebPlayerRef.current) void audio?.play();
    } finally {
      setStarting(false);
    }
  }

  async function stop() {
    setStarting(true);
    try {
      await stopNativeAudioProbe();
      setRunning(false);
      setStatus("Native PCM proof stopped");
      if (resumeWebPlayerRef.current) void audioRef.current?.play();
    } catch (value) {
      setStatus(toCommandError(value).message);
    } finally {
      setStarting(false);
    }
  }

  return (
    <div {...stylex.props(styles.row)}>
      <button
        {...stylex.props(styles.button, (!trackUrn || starting) && styles.disabled)}
        disabled={!trackUrn || starting}
        onClick={running ? stop : start}
        type="button"
      >
        {running ? "Stop native probe" : "Test native PCM"}
      </button>
      <span {...stylex.props(styles.status)}>{status}</span>
    </div>
  );
}

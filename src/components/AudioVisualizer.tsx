import { useEffect, useRef } from "react";
import type { RefObject } from "react";
import * as stylex from "@stylexjs/stylex";
import { getWaveform } from "../api";
import { onNativeAudioProbeEvent } from "../nativeAudioProbe";
import { createVisualizerRenderer } from "../visualizer/createVisualizerRenderer";
import type { WaveformData } from "../types";

const styles = stylex.create({
  canvas: {
    display: {
      default: "block",
      "@media (prefers-reduced-motion: reduce)": "none",
    },
    width: {
      default: "min(840px, calc(100% - 60px))",
      "@media (max-width: 700px)": "calc(100% - 32px)",
    },
    height: 0,
    margin: "0 auto",
    borderColor: {
      default: "#dddde1",
      "@media (prefers-color-scheme: dark)": "#38383e",
    },
    borderStyle: "solid",
    borderWidth: 1,
    borderRadius: 16,
    backgroundColor: {
      default: "#eeeef1",
      "@media (prefers-color-scheme: dark)": "#1b1b1e",
    },
    boxShadow: "0 12px 32px rgb(0 0 0 / 10%)",
    opacity: 0,
    overflow: "hidden",
    pointerEvents: "none",
    transitionDuration: "300ms",
    transitionProperty: "height, margin-top, opacity",
  },
  active: {
    height: {
      default: 220,
      "@media (max-width: 700px)": 160,
    },
    marginTop: 24,
    opacity: {
      default: 0.82,
      "@media (prefers-color-scheme: dark)": 0.95,
    },
  },
});

interface AudioVisualizerProps {
  active: boolean;
  audioRef: RefObject<HTMLAudioElement | null>;
  durationMilliseconds: number;
  waveformUrl: string | null;
}

function fillWaveformBins(
  bins: Uint8Array<ArrayBuffer>,
  waveform: WaveformData,
  progress: number,
) {
  const windowSize = Math.min(
    waveform.samples.length,
    Math.max(bins.length, Math.floor(waveform.samples.length * 0.04)),
  );
  const windowStart = Math.min(Math.max(progress, 0), 1)
    * (waveform.samples.length - windowSize);

  for (let bin = 0; bin < bins.length; bin += 1) {
    const samplePosition = windowStart + (bin / Math.max(bins.length - 1, 1)) * (windowSize - 1);
    const leftIndex = Math.floor(samplePosition);
    const rightIndex = Math.min(leftIndex + 1, waveform.samples.length - 1);
    const interpolation = samplePosition - leftIndex;
    const leftSample = waveform.samples[leftIndex] ?? 0;
    const rightSample = waveform.samples[rightIndex] ?? leftSample;
    const sample = leftSample + (rightSample - leftSample) * interpolation;
    bins[bin] = Math.round(Math.min(sample / waveform.height, 1) * 255);
  }
}

export function AudioVisualizer({
  active,
  audioRef,
  durationMilliseconds,
  waveformUrl,
}: AudioVisualizerProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const activeRef = useRef(active);
  const durationRef = useRef(durationMilliseconds);
  const waveformRef = useRef<WaveformData | null>(null);
  const nativeFrequencyRef = useRef<{
    bins: Uint8Array<ArrayBuffer>;
    receivedAt: number;
  } | null>(null);

  useEffect(() => {
    let current = true;
    let unlisten: (() => void) | undefined;
    void onNativeAudioProbeEvent((event) => {
      if (!current) return;
      if (event.type === "spectrum") {
        nativeFrequencyRef.current = {
          bins: Uint8Array.from(event.bins, (value) => (
            Math.round(Math.min(1, Math.max(0, value)) * 255)
          )),
          receivedAt: performance.now(),
        };
      } else if (event.type === "error"
        || (event.type === "status" && event.state === "stopped")) {
        nativeFrequencyRef.current = null;
      }
    }).then((dispose) => {
      if (current) unlisten = dispose;
      else dispose();
    });

    return () => {
      current = false;
      unlisten?.();
    };
  }, []);

  useEffect(() => {
    activeRef.current = active;
  }, [active]);

  useEffect(() => {
    durationRef.current = durationMilliseconds;
  }, [durationMilliseconds]);

  useEffect(() => {
    waveformRef.current = null;
    if (!waveformUrl || typeof window.AudioContext === "undefined") return;

    let current = true;
    void getWaveform(waveformUrl)
      .then((waveform) => {
        if (current) waveformRef.current = waveform;
      })
      .catch(() => {
        if (current) waveformRef.current = null;
      });

    return () => {
      current = false;
    };
  }, [waveformUrl]);

  useEffect(() => {
    const canvas = canvasRef.current;
    const audio = audioRef.current;
    const reducedMotion = typeof window.matchMedia === "function"
      && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (!canvas || !audio || reducedMotion || typeof window.AudioContext === "undefined") return;

    const renderer = createVisualizerRenderer(canvas);
    if (!renderer) return;
    const audioElement = audio;
    const visualizer = renderer;

    let animationFrame = 0;
    let audioContext: AudioContext | null = null;
    let audioGraphUnavailable = false;
    let analyser: AnalyserNode | null = null;
    let source: MediaElementAudioSourceNode | null = null;
    let frequencyData = new Uint8Array(128);
    let silentFrames = 0;

    function initializeAudioGraph() {
      if (!audioContext && !audioGraphUnavailable) {
        let nextContext: AudioContext | null = null;
        try {
          nextContext = new AudioContext();
          const nextAnalyser = nextContext.createAnalyser();
          nextAnalyser.fftSize = 256;
          nextAnalyser.smoothingTimeConstant = 0.82;
          const nextSource = nextContext.createMediaElementSource(audioElement);
          nextSource.connect(nextAnalyser);
          nextAnalyser.connect(nextContext.destination);

          audioContext = nextContext;
          analyser = nextAnalyser;
          source = nextSource;
          frequencyData = new Uint8Array(nextAnalyser.frequencyBinCount);
        } catch {
          audioGraphUnavailable = true;
          if (nextContext) void nextContext.close();
          return;
        }
      }

      const currentContext = audioContext;
      if (currentContext?.state === "suspended") void currentContext.resume();
    }

    function resumeAudioGraph() {
      if (audioContext?.state === "suspended") void audioContext.resume();
    }

    function draw(time: number) {
      if (activeRef.current) {
        const nativeFrequency = nativeFrequencyRef.current;
        if (nativeFrequency && time - nativeFrequency.receivedAt < 500) {
          visualizer.render(nativeFrequency.bins, time);
          animationFrame = window.requestAnimationFrame(draw);
          return;
        }

        let hasAnalyserData = false;
        if (analyser) {
          analyser.getByteFrequencyData(frequencyData);
          hasAnalyserData = frequencyData.some((value) => value > 0);
          silentFrames = hasAnalyserData ? 0 : silentFrames + 1;
        } else {
          silentFrames = 8;
        }

        const waveform = waveformRef.current;
        if (!hasAnalyserData && silentFrames >= 8 && waveform) {
          const duration = Number.isFinite(audioElement.duration) && audioElement.duration > 0
            ? audioElement.duration
            : durationRef.current / 1000;
          if (duration > 0) {
            fillWaveformBins(frequencyData, waveform, audioElement.currentTime / duration);
          }
        }

        visualizer.render(frequencyData, time);
      }
      animationFrame = window.requestAnimationFrame(draw);
    }

    window.addEventListener("click", initializeAudioGraph, true);
    window.addEventListener("keydown", initializeAudioGraph, true);
    audioElement.addEventListener("play", resumeAudioGraph);
    animationFrame = window.requestAnimationFrame(draw);

    return () => {
      window.cancelAnimationFrame(animationFrame);
      window.removeEventListener("click", initializeAudioGraph, true);
      window.removeEventListener("keydown", initializeAudioGraph, true);
      audioElement.removeEventListener("play", resumeAudioGraph);
      source?.disconnect();
      analyser?.disconnect();
      if (audioContext) void audioContext.close();
      visualizer.destroy();
    };
  }, [audioRef]);

  return (
    <canvas
      {...stylex.props(styles.canvas, active && styles.active)}
      aria-hidden="true"
      ref={canvasRef}
    />
  );
}

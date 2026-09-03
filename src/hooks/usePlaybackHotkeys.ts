import { useCallback, useEffect, useState } from "react";
import type { RefObject } from "react";

interface PlaybackHotkeyOptions {
  audioRef: RefObject<HTMLAudioElement | null>;
  enabled: boolean;
  playbackEnabled: boolean;
  onNext: () => void;
  onPlaybackError: () => void;
  onPrevious: () => void;
}

const SEEK_SECONDS = 5;

function isFormControl(target: EventTarget | null): boolean {
  return target instanceof HTMLElement
    && (target.isContentEditable
      || target.closest("button, input, select, textarea, [contenteditable='true']") !== null);
}

export function usePlaybackHotkeys({
  audioRef,
  enabled,
  playbackEnabled,
  onNext,
  onPlaybackError,
  onPrevious,
}: PlaybackHotkeyOptions) {
  const [shortcutsOpen, setShortcutsOpen] = useState(false);
  const closeShortcuts = useCallback(() => setShortcutsOpen(false), []);

  useEffect(() => {
    if (!enabled) setShortcutsOpen(false);
  }, [enabled]);

  useEffect(() => {
    if (!enabled) return;

    function handleKeyDown(event: KeyboardEvent) {
      if (isFormControl(event.target)) return;

      const audio = audioRef.current;
      const hasCommandModifier = event.altKey || event.ctrlKey || event.metaKey;

      if (event.key === "?" && !hasCommandModifier && !event.repeat) {
        event.preventDefault();
        setShortcutsOpen(true);
        return;
      }

      if (shortcutsOpen || !playbackEnabled) return;

      if (event.code === "Space" && !hasCommandModifier && !event.shiftKey) {
        if (!audio || event.repeat) return;

        event.preventDefault();
        if (audio.paused) {
          void audio.play().catch(onPlaybackError);
        } else {
          audio.pause();
        }
        return;
      }

      if (event.key.toLowerCase() === "m" && !hasCommandModifier && !event.shiftKey) {
        if (!audio || event.repeat) return;

        event.preventDefault();
        audio.muted = !audio.muted;
        return;
      }

      if (hasCommandModifier) return;
      if (!event.shiftKey && (event.key === "ArrowLeft" || event.key === "ArrowRight")) {
        if (!audio) return;

        event.preventDefault();
        const offset = event.key === "ArrowLeft" ? -SEEK_SECONDS : SEEK_SECONDS;
        const nextTime = Math.max(0, audio.currentTime + offset);
        audio.currentTime = Number.isFinite(audio.duration) && audio.duration > 0
          ? Math.min(nextTime, audio.duration)
          : nextTime;
        return;
      }

      if (event.repeat) return;
      if (event.shiftKey && event.key === "ArrowLeft") {
        event.preventDefault();
        onPrevious();
      } else if (event.shiftKey && event.key === "ArrowRight") {
        event.preventDefault();
        onNext();
      }
    }

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [audioRef, enabled, onNext, onPlaybackError, onPrevious, playbackEnabled, shortcutsOpen]);

  return { closeShortcuts, shortcutsOpen };
}

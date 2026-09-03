import { invoke } from "@tauri-apps/api/core";
import type {
  CommandError,
  PlaybackSource,
  SessionState,
  TrackSummary,
  WaveformData,
} from "./types";

function isCommandError(value: unknown): value is CommandError {
  return (
    typeof value === "object" &&
    value !== null &&
    "code" in value &&
    "message" in value &&
    typeof (value as CommandError).code === "string" &&
    typeof (value as CommandError).message === "string"
  );
}

export function toCommandError(value: unknown): CommandError {
  if (isCommandError(value)) return value;
  return {
    code: "unexpected",
    message: typeof value === "string" ? value : "An unexpected error occurred.",
  };
}

export const getSession = () => invoke<SessionState>("get_session");
export const beginLogin = () => invoke<SessionState>("begin_login");
export const signOut = () => invoke<void>("sign_out");
export const getLikedTracks = () =>
  invoke<TrackSummary[]>("get_liked_tracks");
export const resolvePlayback = (trackUrn: string) =>
  invoke<PlaybackSource>("resolve_playback", { trackUrn });
export const startNativeAudioProbe = (trackUrn: string) =>
  invoke<void>("start_native_audio_probe", { trackUrn });
export const stopNativeAudioProbe = () =>
  invoke<void>("stop_native_audio_probe");
export const getWaveform = (waveformUrl: string) =>
  invoke<WaveformData>("get_waveform", { waveformUrl });
export const openSoundCloudUrl = (url: string) =>
  invoke<void>("open_soundcloud_url", { url });

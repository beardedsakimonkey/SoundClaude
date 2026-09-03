import { listen } from "@tauri-apps/api/event";

export type NativeAudioProbeEvent =
  | { type: "status"; state: string }
  | { type: "format"; sampleRate: number; channels: number; fftSize: number; binCount: number }
  | { type: "process"; pid: number; audioObjectID: number; runningOutput: boolean }
  | { type: "spectrum"; time: number; rms: number; bins: number[] }
  | { type: "error"; message: string };

export const onNativeAudioProbeEvent = (
  handler: (event: NativeAudioProbeEvent) => void,
) => listen<NativeAudioProbeEvent>("native-audio-probe", ({ payload }) => handler(payload));

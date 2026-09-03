export interface UserSummary {
  username: string;
  avatarUrl: string | null;
  permalinkUrl: string;
}

export interface SessionState {
  authenticated: boolean;
  user: UserSummary | null;
}

export interface TrackSummary {
  urn: string;
  title: string;
  uploader: string;
  artworkUrl: string | null;
  waveformUrl: string | null;
  permalinkUrl: string;
  uploaderPermalinkUrl: string;
  durationMs: number;
  access: "playable" | "preview";
}

export interface PlaybackSource {
  url: string;
  kind: "hls" | "mp3";
  codec: "aac" | "mp3";
  bitrateKbps: number;
  isPreview: boolean;
}

export interface WaveformData {
  height: number;
  samples: number[];
}

export interface CommandError {
  code: string;
  message: string;
}

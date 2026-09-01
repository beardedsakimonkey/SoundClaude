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
  permalinkUrl: string;
  uploaderPermalinkUrl: string;
  durationMs: number;
  access: "playable" | "preview";
}

export interface PlaybackSource {
  url: string;
  kind: "hls" | "mp3";
  isPreview: boolean;
}

export interface CommandError {
  code: string;
  message: string;
}


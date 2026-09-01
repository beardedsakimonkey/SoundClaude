import * as stylex from "@stylexjs/stylex";
import type { CommandError } from "../types";
import { ErrorNotice } from "./ErrorNotice";

const styles = stylex.create({
  centered: {
    minHeight: "100vh",
    display: "grid",
    placeItems: "center",
    padding: 32,
  },
  card: {
    width: "min(420px, 100%)",
    padding: 40,
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
    borderRadius: 18,
    boxShadow: "0 16px 50px rgb(0 0 0 / 8%)",
    textAlign: "center",
  },
  title: {
    margin: "8px 0",
    fontSize: 28,
  },
  copy: {
    color: {
      default: "#66666d",
      "@media (prefers-color-scheme: dark)": "#aaaab2",
    },
  },
  notice: {
    marginTop: 20,
    textAlign: "left",
  },
  cloudMark: {
    color: "#f50",
    fontSize: 54,
    lineHeight: 1,
  },
  signInButton: {
    marginTop: 12,
    padding: "12px 18px",
    borderWidth: 0,
    borderRadius: 8,
    backgroundColor: "#f50",
    color: "white",
    fontWeight: 650,
  },
  hint: {
    marginBottom: 0,
    fontSize: 13,
  },
});

interface LoginScreenProps {
  authenticating: boolean;
  error: CommandError | null;
  onLogIn: () => void;
}

export function LoginScreen({ authenticating, error, onLogIn }: LoginScreenProps) {
  return (
    <main {...stylex.props(styles.centered)}>
      <section {...stylex.props(styles.card)} aria-labelledby="login-title">
        <div {...stylex.props(styles.cloudMark)} aria-hidden="true">☁</div>
        <h1 {...stylex.props(styles.title)} id="login-title">SoundClaude</h1>
        <p {...stylex.props(styles.copy)}>Sign in to load and play your liked tracks.</p>
        {error && (
          <div {...stylex.props(styles.notice)}>
            <ErrorNotice error={error} />
          </div>
        )}
        <button {...stylex.props(styles.signInButton)} disabled={authenticating} onClick={onLogIn} type="button">
          {authenticating ? "Waiting for SoundCloud…" : "Sign in with SoundCloud"}
        </button>
        {authenticating && (
          <p {...stylex.props(styles.copy, styles.hint)}>
            Complete sign-in in your browser. This request expires after five minutes.
          </p>
        )}
      </section>
    </main>
  );
}

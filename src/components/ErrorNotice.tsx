import * as stylex from "@stylexjs/stylex";
import type { CommandError } from "../types";

const styles = stylex.create({
  notice: {
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
    gap: 18,
    marginBottom: 18,
    padding: "12px 14px",
    borderRadius: 8,
    backgroundColor: "#ffebea",
    color: "#9b1c16",
  },
  retryButton: {
    borderWidth: 0,
    padding: 0,
    backgroundColor: "transparent",
    color: "inherit",
    textDecoration: "underline",
  },
});

interface ErrorNoticeProps {
  error: CommandError;
  onRetry?: () => void;
}

export function ErrorNotice({ error, onRetry }: ErrorNoticeProps) {
  return (
    <div {...stylex.props(styles.notice)} role="alert">
      <span>{error.message}</span>
      {onRetry && (
        <button {...stylex.props(styles.retryButton)} onClick={onRetry} type="button">
          Retry
        </button>
      )}
    </div>
  );
}

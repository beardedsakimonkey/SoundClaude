import { useEffect, useRef } from "react";
import * as stylex from "@stylexjs/stylex";

const styles = stylex.create({
  dialog: {
    width: "min(440px, calc(100vw - 48px))",
    padding: 0,
    borderWidth: 0,
    borderRadius: 16,
    backgroundColor: {
      default: "#fff",
      "@media (prefers-color-scheme: dark)": "#242427",
    },
    color: "inherit",
    boxShadow: "0 24px 80px rgb(0 0 0 / 30%)",
    "::backdrop": {
      backgroundColor: "rgb(0 0 0 / 48%)",
      backdropFilter: "blur(3px)",
    },
  },
  content: {
    padding: 26,
  },
  header: {
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
    gap: 20,
    marginBottom: 22,
  },
  title: {
    margin: 0,
    fontSize: 20,
  },
  closeButton: {
    display: "grid",
    placeItems: "center",
    width: 34,
    height: 34,
    padding: 0,
    borderWidth: 0,
    borderRadius: "50%",
    backgroundColor: {
      default: "#eeeef0",
      ":hover": "#e1e1e4",
      "@media (prefers-color-scheme: dark)": "#38383d",
    },
    color: "inherit",
    fontSize: 22,
    lineHeight: 1,
  },
  list: {
    display: "grid",
    gap: 14,
    margin: 0,
  },
  row: {
    display: "grid",
    gridTemplateColumns: "minmax(150px, auto) 1fr",
    alignItems: "center",
    gap: 20,
  },
  keys: {
    display: "flex",
    alignItems: "center",
    gap: 5,
    margin: 0,
  },
  key: {
    minWidth: 30,
    padding: "4px 8px",
    borderColor: {
      default: "#d5d5d9",
      "@media (prefers-color-scheme: dark)": "#525259",
    },
    borderStyle: "solid",
    borderWidth: 1,
    borderRadius: 6,
    backgroundColor: {
      default: "#f4f4f5",
      "@media (prefers-color-scheme: dark)": "#303034",
    },
    boxShadow: {
      default: "0 1px 0 #c7c7cb",
      "@media (prefers-color-scheme: dark)": "0 1px 0 #171719",
    },
    color: "inherit",
    fontFamily: "inherit",
    fontSize: 12,
    fontWeight: 650,
    textAlign: "center",
  },
  separator: {
    color: {
      default: "#77777e",
      "@media (prefers-color-scheme: dark)": "#aaaab2",
    },
    fontSize: 12,
  },
  description: {
    margin: 0,
    color: {
      default: "#55555c",
      "@media (prefers-color-scheme: dark)": "#c5c5cb",
    },
    fontSize: 14,
  },
});

interface KeyboardShortcutsDialogProps {
  onClose: () => void;
  open: boolean;
}

export function KeyboardShortcutsDialog({ onClose, open }: KeyboardShortcutsDialogProps) {
  const dialogRef = useRef<HTMLDialogElement>(null);

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;

    if (open && !dialog.open) dialog.showModal();
    if (!open && dialog.open) dialog.close();
  }, [open]);

  return (
    <dialog
      {...stylex.props(styles.dialog)}
      aria-labelledby="keyboard-shortcuts-title"
      onCancel={(event) => {
        event.preventDefault();
        onClose();
      }}
      onClick={(event) => {
        if (event.target === event.currentTarget) onClose();
      }}
      ref={dialogRef}
    >
      <div {...stylex.props(styles.content)}>
        <div {...stylex.props(styles.header)}>
          <h2 {...stylex.props(styles.title)} id="keyboard-shortcuts-title">Keyboard shortcuts</h2>
          <button
            {...stylex.props(styles.closeButton)}
            aria-label="Close keyboard shortcuts"
            autoFocus
            onClick={onClose}
            type="button"
          >
            ×
          </button>
        </div>

        <dl {...stylex.props(styles.list)}>
          <div {...stylex.props(styles.row)}>
            <dt {...stylex.props(styles.keys)}><kbd {...stylex.props(styles.key)}>Space</kbd></dt>
            <dd {...stylex.props(styles.description)}>Play or pause</dd>
          </div>
          <div {...stylex.props(styles.row)}>
            <dt {...stylex.props(styles.keys)}>
              <kbd {...stylex.props(styles.key)}>←</kbd>
              <span {...stylex.props(styles.separator)}>/</span>
              <kbd {...stylex.props(styles.key)}>→</kbd>
            </dt>
            <dd {...stylex.props(styles.description)}>Seek back or forward 5 seconds</dd>
          </div>
          <div {...stylex.props(styles.row)}>
            <dt {...stylex.props(styles.keys)}>
              <kbd {...stylex.props(styles.key)}>Shift</kbd>
              <span {...stylex.props(styles.separator)}>+</span>
              <kbd {...stylex.props(styles.key)}>←</kbd>
              <span {...stylex.props(styles.separator)}>/</span>
              <kbd {...stylex.props(styles.key)}>→</kbd>
            </dt>
            <dd {...stylex.props(styles.description)}>Previous or next track</dd>
          </div>
          <div {...stylex.props(styles.row)}>
            <dt {...stylex.props(styles.keys)}><kbd {...stylex.props(styles.key)}>M</kbd></dt>
            <dd {...stylex.props(styles.description)}>Mute or unmute</dd>
          </div>
          <div {...stylex.props(styles.row)}>
            <dt {...stylex.props(styles.keys)}><kbd {...stylex.props(styles.key)}>?</kbd></dt>
            <dd {...stylex.props(styles.description)}>Show keyboard shortcuts</dd>
          </div>
          <div {...stylex.props(styles.row)}>
            <dt {...stylex.props(styles.keys)}><kbd {...stylex.props(styles.key)}>Esc</kbd></dt>
            <dd {...stylex.props(styles.description)}>Close this dialog</dd>
          </div>
        </dl>
      </div>
    </dialog>
  );
}

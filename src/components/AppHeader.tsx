import * as stylex from "@stylexjs/stylex";
import type { UserSummary } from "../types";

const styles = stylex.create({
  header: {
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
    gap: 24,
    padding: "28px 34px 20px",
    backgroundColor: {
      default: "white",
      "@media (prefers-color-scheme: dark)": "#222225",
    },
    borderBottomColor: {
      default: "#dedee2",
      "@media (prefers-color-scheme: dark)": "#3a3a3f",
    },
    borderBottomStyle: "solid",
    borderBottomWidth: 1,
  },
  title: {
    margin: "2px 0 0",
    fontSize: 28,
  },
  eyebrow: {
    margin: 0,
    color: {
      default: "#77777e",
      "@media (prefers-color-scheme: dark)": "#aaaab2",
    },
    fontSize: 11,
    fontWeight: 750,
    letterSpacing: "0.12em",
    textTransform: "uppercase",
  },
  account: {
    display: "flex",
    alignItems: "center",
    gap: 10,
  },
  avatar: {
    width: 34,
    height: 34,
    borderRadius: "50%",
    objectFit: "cover",
  },
  profileLink: {
    borderWidth: 0,
    padding: 0,
    backgroundColor: "transparent",
    color: "inherit",
    fontWeight: 650,
    textAlign: "left",
    textDecoration: {
      default: "none",
      ":hover": "underline",
    },
  },
  signOutButton: {
    padding: "8px 12px",
    borderWidth: 0,
    borderRadius: 8,
    backgroundColor: {
      default: "#ececef",
      "@media (prefers-color-scheme: dark)": "#39393e",
    },
    color: {
      default: "#29292d",
      "@media (prefers-color-scheme: dark)": "#f5f5f7",
    },
    fontWeight: 650,
  },
});

interface AppHeaderProps {
  user: UserSummary;
  onOpenProfile: () => void;
  onSignOut: () => void;
}

export function AppHeader({ user, onOpenProfile, onSignOut }: AppHeaderProps) {
  return (
    <header {...stylex.props(styles.header)}>
      <div>
        <p {...stylex.props(styles.eyebrow)}>Your library</p>
        <h1 {...stylex.props(styles.title)}>Liked tracks</h1>
      </div>
      <div {...stylex.props(styles.account)}>
        {user.avatarUrl && <img {...stylex.props(styles.avatar)} src={user.avatarUrl} alt="" />}
        <button {...stylex.props(styles.profileLink)} onClick={onOpenProfile} type="button">
          {user.username}
        </button>
        <button {...stylex.props(styles.signOutButton)} onClick={onSignOut} type="button">
          Sign out
        </button>
      </div>
    </header>
  );
}

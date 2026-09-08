import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from "react";
import { api, ApiError, setUnauthorizedListener } from "./api";

interface AuthState {
  authenticated: boolean;
  checking: boolean;
  username: string | null;
  login: (username: string, password: string) => Promise<string | null>;
  logout: () => Promise<void>;
}

const AuthContext = createContext<AuthState | null>(null);

/** Best-effort GET /auth/me — never flips auth state, used only for display. */
async function fetchMe(): Promise<string | null> {
  try {
    const res = await fetch("/api/v1/auth/me", { credentials: "same-origin" });
    if (!res.ok) return null;
    const data = (await res.json()) as { username?: string };
    return typeof data?.username === "string" ? data.username : null;
  } catch {
    return null;
  }
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [authenticated, setAuthenticated] = useState(false);
  const [checking, setChecking] = useState(true);
  const [username, setUsername] = useState<string | null>(null);

  useEffect(() => {
    setUnauthorizedListener(() => setAuthenticated(false));
    // A cheap authenticated probe: if it succeeds there is no auth gate (or we
    // already have a session); if it 401s, api.ts flips us to the login screen.
    api
      .status()
      .then(() => {
        setAuthenticated(true);
        void fetchMe().then(setUsername);
      })
      .catch(() => setAuthenticated(false))
      .finally(() => setChecking(false));
    return () => setUnauthorizedListener(null);
  }, []);

  const login = useCallback(async (user: string, password: string) => {
    try {
      await api.login(user, password);
    } catch (err) {
      if (err instanceof ApiError && err.message && err.message !== "Non authentifié") {
        return err.message;
      }
      return "Identifiants invalides";
    }
    setAuthenticated(true);
    void fetchMe().then(setUsername);
    return null;
  }, []);

  const logout = useCallback(async () => {
    try {
      await api.logout();
    } catch {
      // ignore
    }
    setUsername(null);
    setAuthenticated(false);
  }, []);

  return (
    <AuthContext.Provider value={{ authenticated, checking, username, login, logout }}>
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth must be used within AuthProvider");
  return ctx;
}

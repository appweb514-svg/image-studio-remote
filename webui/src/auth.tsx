import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from "react";
import { api, setUnauthorizedListener } from "./api";

interface AuthState {
  authenticated: boolean;
  checking: boolean;
  login: (token: string) => Promise<boolean>;
  logout: () => Promise<void>;
}

const AuthContext = createContext<AuthState | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [authenticated, setAuthenticated] = useState(false);
  const [checking, setChecking] = useState(true);

  useEffect(() => {
    setUnauthorizedListener(() => setAuthenticated(false));
    // A cheap authenticated probe: if it succeeds there is no auth gate (or we
    // already have a session); if it 401s, api.ts flips us to the login screen.
    api
      .status()
      .then(() => setAuthenticated(true))
      .catch(() => setAuthenticated(false))
      .finally(() => setChecking(false));
    return () => setUnauthorizedListener(null);
  }, []);

  const login = useCallback(async (token: string) => {
    try {
      await api.login(token);
      setAuthenticated(true);
      return true;
    } catch {
      return false;
    }
  }, []);

  const logout = useCallback(async () => {
    try {
      await api.logout();
    } catch {
      // ignore
    }
    setAuthenticated(false);
  }, []);

  return (
    <AuthContext.Provider value={{ authenticated, checking, login, logout }}>
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth must be used within AuthProvider");
  return ctx;
}

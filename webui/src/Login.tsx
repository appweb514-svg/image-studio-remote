import { useState, type FormEvent } from "react";
import { useAuth } from "./auth";

export function LoginScreen() {
  const { login } = useAuth();
  const [token, setToken] = useState("");
  const [error, setError] = useState(false);
  const [busy, setBusy] = useState(false);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (!token.trim() || busy) return;
    setBusy(true);
    setError(false);
    const ok = await login(token.trim());
    setBusy(false);
    if (!ok) setError(true);
  };

  return (
    <div className="login-screen">
      <form className="login-card" onSubmit={submit}>
        <h1>
          MLXBits <strong>Image Studio</strong>
        </h1>
        <p className="muted">Session protégée — saisissez votre jeton d'accès.</p>
        <input
          type="password"
          placeholder="Jeton d'accès"
          value={token}
          autoFocus
          onChange={(e) => setToken(e.target.value)}
        />
        {error && <p className="error-text">Jeton invalide, réessayez.</p>}
        <button className="btn btn-primary" type="submit" disabled={busy || !token.trim()}>
          {busy ? "Connexion…" : "Se connecter"}
        </button>
      </form>
    </div>
  );
}

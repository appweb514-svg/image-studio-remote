import { useState, type AnimationEvent, type FormEvent } from "react";
import { useAuth } from "./auth";
import { Aurora, Monogram } from "./components/Aurora";

export function LoginScreen() {
  const { login } = useAuth();
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [shaking, setShaking] = useState(false);
  const [busy, setBusy] = useState(false);

  const onAnimationEnd = (e: AnimationEvent<HTMLFormElement>) => {
    if (e.animationName === "login-shake") setShaking(false);
  };

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (!username.trim() || !password || busy) return;
    setBusy(true);
    setError(null);
    const err = await login(username.trim(), password);
    setBusy(false);
    if (err) {
      setError(err);
      setShaking(true);
    }
  };

  return (
    <div className="login-screen">
      <Aurora />
      <form
        className={`login-card glass ${shaking ? "shake" : ""}`}
        onAnimationEnd={onAnimationEnd}
        onSubmit={submit}
      >
        <div className="login-logo">
          <Monogram size={64} />
        </div>
        <h1>Image Studio</h1>
        <p className="login-tagline">Atelier d'images — chambre noire numérique</p>
        <hr className="login-rule" />
        <p className="muted">
          <span className="micro-label">Séance protégée</span>
        </p>
        <input
          type="text"
          autoComplete="username"
          placeholder="Identifiant"
          value={username}
          autoFocus
          onChange={(e) => setUsername(e.target.value)}
        />
        <input
          type="password"
          autoComplete="current-password"
          placeholder="Mot de passe"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
        />
        {error && (
          <p className="error-text" role="alert">
            {error}
          </p>
        )}
        <button
          className="btn btn-primary btn-lg"
          type="submit"
          disabled={busy || !username.trim() || !password}
        >
          {busy && <span className="spinner" aria-hidden />}
          {busy ? "Connexion…" : "Se connecter"}
        </button>
      </form>
    </div>
  );
}

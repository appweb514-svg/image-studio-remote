import { useCallback, useEffect, useId, useRef, useState } from "react";
import { api, ApiError } from "../api";
import { useEvents } from "../sse";
import { useToast } from "../components/Toast";
import { UpscaleStatusBadge } from "../components/StatusBadge";
import type { SystemStatus, UpscaleJobDTO } from "../types";

/** Flash the value briefly whenever it changes. */
function useFlash(value: string | number) {
  const [flash, setFlash] = useState(false);
  const prev = useRef(value);
  useEffect(() => {
    if (prev.current !== value) {
      prev.current = value;
      setFlash(true);
      const t = window.setTimeout(() => setFlash(false), 800);
      return () => window.clearTimeout(t);
    }
  }, [value]);
  return flash;
}

function Metric({ label, value, sub }: { label: string; value: string | number; sub?: string }) {
  const flash = useFlash(value);
  return (
    <div className="card glass metric-card">
      <span className="metric-label">{label}</span>
      <span className={`metric-value tnum ${flash ? "flash" : ""}`}>{value}</span>
      {sub && <span className="metric-sub">{sub}</span>}
    </div>
  );
}

function Gauge({ value, label }: { value: number; label: string }) {
  const uid = useId();
  const pct = Math.min(100, Math.max(0, value * 100));
  const r = 30;
  const circ = 2 * Math.PI * r;
  return (
    <div className="gauge">
      <svg viewBox="0 0 72 72" className="gauge-svg" role="img" aria-label={label}>
        <defs>
          <linearGradient id={uid} x1="0" y1="0" x2="1" y2="1">
            <stop stopColor="#7c3aed" />
            <stop offset="1" stopColor="#22d3ee" />
          </linearGradient>
        </defs>
        <circle cx="36" cy="36" r={r} className="gauge-track" />
        <circle
          cx="36"
          cy="36"
          r={r}
          className="gauge-arc"
          stroke={`url(#${uid})`}
          style={{ strokeDasharray: circ, strokeDashoffset: circ * (1 - pct / 100) }}
        />
      </svg>
      <div className="gauge-label">
        <span className="tnum gauge-pct">{Math.round(pct)} %</span>
        <span className="muted">{label}</span>
      </div>
    </div>
  );
}

export function DashboardPage() {
  const toast = useToast();
  const [status, setStatus] = useState<SystemStatus | null>(null);
  const [upJobs, setUpJobs] = useState<UpscaleJobDTO[]>([]);

  const refresh = useCallback(async () => {
    try {
      setStatus(await api.status());
    } catch (err) {
      if (!(err instanceof ApiError && err.status === 401))
        toast("Impossible de charger l'état du système", "error");
    }
  }, [toast]);

  const refreshUpscale = useCallback(async () => {
    try {
      setUpJobs((await api.upscaleJobs()).slice(0, 10));
    } catch (err) {
      if (!(err instanceof ApiError && err.status === 401))
        toast("Impossible de charger les travaux d'upscaling", "error");
    }
  }, [toast]);

  useEffect(() => {
    void refresh();
    void refreshUpscale();
    const t = window.setInterval(() => {
      void refresh();
      void refreshUpscale();
    }, 5000);
    return () => window.clearInterval(t);
  }, [refresh, refreshUpscale]);

  useEvents(
    {
      queueChanged: () => void refresh(),
      modelLoaded: () => void refresh(),
      modelUnloaded: () => void refresh(),
      upscaleQueued: () => void refreshUpscale(),
      upscaleStarted: () => void refreshUpscale(),
      upscaleProgress: () => void refreshUpscale(),
      upscaleCompleted: () => void refreshUpscale(),
      upscaleFailed: () => void refreshUpscale(),
    },
    [refresh, refreshUpscale],
  );

  if (!status)
    return (
      <div className="page">
        <h1>Tableau de bord</h1>
        <p className="muted">Chargement…</p>
      </div>
    );

  const s = status.system;
  const mem = s.memory;
  const pressure = mem.pressure_ratio;
  const running =
    status.queue.running_flux + status.queue.running_krea2 + status.queue.running_zimage;

  return (
    <div className="page">
      <div className="page-head">
        <h1>Tableau de bord</h1>
        <span className="badge badge-running">
          <span className="status-dot" aria-hidden />
          {status.remoteAccess.connected_clients} client
          {status.remoteAccess.connected_clients > 1 ? "s" : ""}
        </span>
      </div>

      <div className="metrics-row">
        <Metric label="File d'attente" value={status.queue.pending} sub="travaux en attente" />
        <Metric label="En cours" value={running} sub="générations actives" />
        <Metric
          label="Stockage libre"
          value={`${s.storage.free_gb.toFixed(0)} Go`}
          sub={`sur ${s.storage.total_gb.toFixed(0)} Go`}
        />
        <Metric
          label="Mémoire"
          value={`${mem.total_gb.toFixed(0)} Go`}
          sub={mem.swap_used_gb !== undefined ? `swap ${mem.swap_used_gb.toFixed(1)} Go` : undefined}
        />
      </div>

      <div className="dash-grid">
        <section className="card glass dash-card">
          <h2>Machine</h2>
          <dl className="detail-grid">
            <dt>Puce</dt>
            <dd>
              {s.chip}
              {s.chip_generation ? ` (${s.chip_generation})` : ""}
            </dd>
            <dt>Stockage</dt>
            <dd>
              {s.storage.free_gb.toFixed(0)} Go libres / {s.storage.total_gb.toFixed(0)} Go
            </dd>
          </dl>
          {pressure !== undefined && (
            <Gauge value={pressure} label={`Pression mémoire : ${(pressure * 100).toFixed(0)} %`} />
          )}
          <Gauge
            value={s.storage.total_gb > 0 ? s.storage.free_gb / s.storage.total_gb : 0}
            label="Espace libre"
          />
        </section>

        <section className="card glass dash-card">
          <h2>Modèle chargé</h2>
          {s.loaded_model ? (
            <dl className="detail-grid">
              <dt>Modèle</dt>
              <dd>{s.loaded_model}</dd>
              {s.loaded_model_memory_gb !== undefined && (
                <>
                  <dt>Mémoire</dt>
                  <dd>{s.loaded_model_memory_gb.toFixed(1)} Go</dd>
                </>
              )}
            </dl>
          ) : (
            <p className="muted">Aucun modèle chargé.</p>
          )}
        </section>

        <section className="card glass dash-card">
          <h2>File d'attente</h2>
          <dl className="detail-grid">
            <dt>En attente</dt>
            <dd>{status.queue.pending}</dd>
            <dt>Flux en cours</dt>
            <dd>{status.queue.running_flux}</dd>
            <dt>Krea 2 en cours</dt>
            <dd>{status.queue.running_krea2}</dd>
            <dt>Z-Image en cours</dt>
            <dd>{status.queue.running_zimage}</dd>
            <dt>Longueur totale</dt>
            <dd>{s.queue_length}</dd>
          </dl>
        </section>

        <section className="card glass dash-card">
          <h2>UpScaler</h2>
          {upJobs.length === 0 ? (
            <p className="muted">Aucun travail d'upscaling.</p>
          ) : (
            <ul className="up-job-list">
              {upJobs.map((j) => (
                <li key={j.id}>
                  <UpscaleStatusBadge status={j.status} />
                  <span className="mono muted">#{j.id.slice(0, 8)}</span>
                  <span>{j.model}</span>
                  {j.status === "running" && (
                    <span className="muted mono">
                      {j.phase ?? ""}
                      {j.tiles_total ? ` ${j.tiles_done ?? 0}/${j.tiles_total}` : ""}
                    </span>
                  )}
                  {j.status === "failed" && j.error && (
                    <span className="error-text">{j.error}</span>
                  )}
                </li>
              ))}
            </ul>
          )}
        </section>

        <section className="card glass dash-card">
          <h2>Versions</h2>
          <dl className="detail-grid">
            <dt>Application</dt>
            <dd>{s.versions.app}</dd>
            {s.versions.mflux && (
              <>
                <dt>mflux</dt>
                <dd>{s.versions.mflux}</dd>
              </>
            )}
            {s.versions.mac_os && (
              <>
                <dt>macOS</dt>
                <dd>{s.versions.mac_os}</dd>
              </>
            )}
            <dt>Accès distant</dt>
            <dd>
              {status.remoteAccess.is_running
                ? status.remoteAccess.allow_lan
                  ? "LAN ouvert"
                  : "Local"
                : "Inactif"}
              {status.remoteAccess.require_auth ? " · auth requise" : ""}
            </dd>
          </dl>
        </section>
      </div>
    </div>
  );
}

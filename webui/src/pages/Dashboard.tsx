import { useCallback, useEffect, useState } from "react";
import { api, ApiError } from "../api";
import { useEvents } from "../sse";
import { useToast } from "../components/Toast";
import { ProgressBar } from "../components/ProgressBar";
import { UpscaleStatusBadge } from "../components/StatusBadge";
import type { SystemStatus, UpscaleJobDTO } from "../types";

function Gauge({ value, label }: { value: number; label: string }) {
  const pct = Math.min(100, Math.max(0, value * 100));
  return (
    <div className="gauge">
      <ProgressBar value={pct} />
      <span className="muted">{label}</span>
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

  if (!status) return <div className="page"><h1>Tableau de bord</h1><p className="muted">Chargement…</p></div>;

  const s = status.system;
  const mem = s.memory;
  const pressure = mem.pressure_ratio;

  return (
    <div className="page">
      <div className="page-head">
        <h1>Tableau de bord</h1>
        <span className="badge badge-running">
          {status.remoteAccess.connected_clients} client{status.remoteAccess.connected_clients > 1 ? "s" : ""}
        </span>
      </div>
      <div className="dash-grid">
        <section className="card dash-card">
          <h2>Machine</h2>
          <dl className="detail-grid">
            <dt>Puce</dt>
            <dd>
              {s.chip}
              {s.chip_generation ? ` (${s.chip_generation})` : ""}
            </dd>
            <dt>RAM totale</dt>
            <dd>{mem.total_gb.toFixed(0)} Go</dd>
            {mem.swap_used_gb !== undefined && (
              <>
                <dt>Swap utilisé</dt>
                <dd>{mem.swap_used_gb.toFixed(1)} Go</dd>
              </>
            )}
            <dt>Stockage libre</dt>
            <dd>
              {s.storage.free_gb.toFixed(0)} Go / {s.storage.total_gb.toFixed(0)} Go
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

        <section className="card dash-card">
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

        <section className="card dash-card">
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

        <section className="card dash-card">
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

        <section className="card dash-card">
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

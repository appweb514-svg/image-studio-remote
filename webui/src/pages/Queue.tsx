import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { api, ApiError } from "../api";
import { useEvents } from "../sse";
import { useToast } from "../components/Toast";
import { StatusBadge, UpscaleStatusBadge } from "../components/StatusBadge";
import { ProgressBar } from "../components/ProgressBar";
import type { JobDTO, JobStatus, UpscaleJobDTO } from "../types";

const SECTIONS: { status: JobStatus; label: string }[] = [
  { status: "running", label: "En cours" },
  { status: "pending", label: "En attente" },
  { status: "completed", label: "Terminés" },
  { status: "failed", label: "Échecs" },
  { status: "cancelled", label: "Annulés" },
];

export function QueuePage() {
  const toast = useToast();
  const [jobs, setJobs] = useState<JobDTO[]>([]);
  const [upJobs, setUpJobs] = useState<UpscaleJobDTO[]>([]);
  const [loaded, setLoaded] = useState(false);
  const dragId = useRef<string | null>(null);

  const refresh = useCallback(async () => {
    try {
      setJobs(await api.queue());
      setLoaded(true);
    } catch (err) {
      if (!(err instanceof ApiError && err.status === 401))
        toast("Impossible de charger la file", "error");
    }
  }, [toast]);

  const refreshUpscale = useCallback(async () => {
    try {
      setUpJobs(await api.upscaleJobs());
    } catch (err) {
      if (!(err instanceof ApiError && err.status === 401))
        toast("Impossible de charger les travaux d'upscaling", "error");
    }
  }, [toast]);

  useEffect(() => {
    void refresh();
    void refreshUpscale();
  }, [refresh, refreshUpscale]);

  useEvents(
    {
      jobCreated: () => void refresh(),
      jobStarted: () => void refresh(),
      jobProgress: (p) => {
        const e = p as { job_id: string; step: number; total_steps: number; status_line?: string };
        setJobs((prev) =>
          prev.map((j) =>
            j.id === e.job_id
              ? {
                  ...j,
                  status: "running",
                  current_step: e.step,
                  total_steps: e.total_steps,
                  progress: e.total_steps > 0 ? (e.step / e.total_steps) * 100 : 0,
                  status_line: e.status_line,
                }
              : j,
          ),
        );
      },
      jobCompleted: () => void refresh(),
      jobFailed: () => void refresh(),
      jobCancelled: () => void refresh(),
      queueChanged: () => void refresh(),
      upscaleQueued: () => void refreshUpscale(),
      upscaleStarted: () => void refreshUpscale(),
      upscaleProgress: () => void refreshUpscale(),
      upscaleCompleted: () => void refreshUpscale(),
      upscaleFailed: () => void refreshUpscale(),
    },
    [refresh, refreshUpscale],
  );

  const byStatus = useMemo(() => {
    const map = new Map<JobStatus, JobDTO[]>();
    for (const s of SECTIONS.map((x) => x.status)) map.set(s, []);
    for (const j of jobs) map.get(j.status)?.push(j);
    return map;
  }, [jobs]);

  const pending = byStatus.get("pending") ?? [];

  const reorder = async (newPending: JobDTO[]) => {
    const pendingIds = new Set(pending.map((j) => j.id));
    const newOrder = [
      ...newPending.map((j) => j.id),
      ...jobs.filter((j) => !pendingIds.has(j.id)).map((j) => j.id),
    ];
    setJobs(jobs.slice().sort((a, b) => {
      const ia = newOrder.indexOf(a.id);
      const ib = newOrder.indexOf(b.id);
      return (ia === -1 ? 1e9 : ia) - (ib === -1 ? 1e9 : ib);
    }));
    try {
      await api.reorder(newOrder);
    } catch {
      toast("Réordonnancement refusé", "error");
      void refresh();
    }
  };

  const move = (id: string, delta: number) => {
    const idx = pending.findIndex((j) => j.id === id);
    const target = idx + delta;
    if (idx === -1 || target < 0 || target >= pending.length) return;
    const next = pending.slice();
    const [item] = next.splice(idx, 1);
    next.splice(target, 0, item);
    void reorder(next);
  };

  const onDrop = (targetId: string) => {
    const srcId = dragId.current;
    dragId.current = null;
    if (!srcId || srcId === targetId) return;
    const next = pending.slice();
    const from = next.findIndex((j) => j.id === srcId);
    const to = next.findIndex((j) => j.id === targetId);
    if (from === -1 || to === -1) return;
    const [item] = next.splice(from, 1);
    next.splice(to, 0, item);
    void reorder(next);
  };

  const act = async (id: string, action: "cancel" | "retry" | "duplicate" | "delete") => {
    try {
      if (action === "cancel") await api.cancelJob(id);
      if (action === "retry") await api.retryJob(id);
      if (action === "duplicate") await api.duplicateJob(id);
      if (action === "delete") await api.deleteJob(id);
      toast("Action effectuée", "success");
      void refresh();
    } catch (err) {
      toast(err instanceof ApiError ? err.message : "Action impossible", "error");
    }
  };

  return (
    <div className="page">
      <div className="page-head">
        <h1>File d'attente</h1>
        <button className="btn btn-ghost" onClick={() => void refresh()}>
          Rafraîchir
        </button>
      </div>
      {!loaded && <p className="muted">Chargement…</p>}
      {loaded && jobs.length === 0 && <p className="muted">Aucun travail dans la file.</p>}
      {SECTIONS.map(({ status, label }) => {
        const list = byStatus.get(status) ?? [];
        if (list.length === 0) return null;
        return (
          <section key={status} className="queue-section">
            <h2>
              {label} <span className="count">{list.length}</span>
            </h2>
            <div className="job-list">
              {list.map((job) => (
                <article
                  key={job.id}
                  className={`card job ${status === "pending" ? "draggable" : ""}`}
                  draggable={status === "pending"}
                  onDragStart={() => (dragId.current = job.id)}
                  onDragOver={(e) => status === "pending" && e.preventDefault()}
                  onDrop={() => status === "pending" && onDrop(job.id)}
                >
                  <div className="job-main">
                    <div className="job-title">
                      {status === "pending" && <span className="drag-handle" title="Glisser">⠿</span>}
                      <StatusBadge status={job.status} />
                      <span className="mono muted">#{job.id.slice(0, 8)}</span>
                      {job.model && <span className="job-model">{job.model}</span>}
                      {job.board && <span className="job-board">📌 {job.board}</span>}
                    </div>
                    {job.prompt && <p className="job-prompt">{job.prompt}</p>}
                    {job.status === "running" && (
                      <>
                        <ProgressBar value={job.progress} indeterminate={job.total_steps === 0} />
                        <p className="muted mono">
                          Pas {job.current_step}/{job.total_steps || "?"}
                          {job.status_line ? ` — ${job.status_line}` : ""}
                        </p>
                      </>
                    )}
                    {job.status === "failed" && job.status_message && (
                      <p className="error-text">{job.status_message}</p>
                    )}
                  </div>
                  <div className="job-actions">
                    {status === "pending" && (
                      <>
                        <button className="btn btn-chip" onClick={() => move(job.id, -1)} aria-label="Monter">↑</button>
                        <button className="btn btn-chip" onClick={() => move(job.id, 1)} aria-label="Descendre">↓</button>
                        <button className="btn btn-chip" onClick={() => void act(job.id, "cancel")}>
                          Annuler
                        </button>
                      </>
                    )}
                    {status === "running" && (
                      <button className="btn btn-chip" onClick={() => void act(job.id, "cancel")}>
                        Annuler
                      </button>
                    )}
                    {(status === "failed" || status === "cancelled") && (
                      <button className="btn btn-chip" onClick={() => void act(job.id, "retry")}>
                        Réessayer
                      </button>
                    )}
                    {status === "completed" && (
                      <button className="btn btn-chip" onClick={() => void act(job.id, "duplicate")}>
                        Dupliquer
                      </button>
                    )}
                    <button className="btn btn-chip btn-danger-text" onClick={() => void act(job.id, "delete")}>
                      Supprimer
                    </button>
                  </div>
                </article>
              ))}
            </div>
          </section>
        );
      })}

      {upJobs.length > 0 && (
        <section className="queue-section">
          <h2>
            UpScaler <span className="count">{upJobs.length}</span>
          </h2>
          <div className="job-list">
            {upJobs.slice(0, 10).map((j) => (
              <article key={j.id} className="card job">
                <div className="job-main">
                  <div className="job-title">
                    <UpscaleStatusBadge status={j.status} />
                    <span className="mono muted">#{j.id.slice(0, 8)}</span>
                    <span className="job-model">{j.model}</span>
                  </div>
                  {j.status === "running" && (
                    <>
                      <ProgressBar
                        value={
                          j.tiles_total && (j.tiles_done ?? 0) > 0
                            ? Math.min(100, ((j.tiles_done ?? 0) / j.tiles_total) * 100)
                            : 0
                        }
                        indeterminate={!j.tiles_total}
                      />
                      <p className="muted mono">
                        {j.phase ?? "Traitement"}
                        {j.tiles_total ? ` — tuiles ${j.tiles_done ?? 0}/${j.tiles_total}` : ""}
                      </p>
                    </>
                  )}
                  {j.status === "failed" && j.error && <p className="error-text">{j.error}</p>}
                </div>
              </article>
            ))}
          </div>
        </section>
      )}
    </div>
  );
}

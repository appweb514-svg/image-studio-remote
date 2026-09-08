import { useCallback, useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { api, ApiError } from "../api";
import { useEvents } from "../sse";
import { useToast } from "./Toast";
import { ProgressBar } from "./ProgressBar";
import type { GalleryItemDTO, UpscaleJobDTO, UpscaleModel, UpscaleRecommendation } from "../types";

const AUTO = "";

export function UpscaleModal({
  item,
  onClose,
  onCompleted,
}: {
  item: GalleryItemDTO;
  onClose: () => void;
  onCompleted?: () => void;
}) {
  const toast = useToast();
  const [models, setModels] = useState<UpscaleModel[] | null>(null);
  const [recs, setRecs] = useState<UpscaleRecommendation[] | null>(null);
  const [recsLoaded, setRecsLoaded] = useState(false);

  const [model, setModel] = useState(AUTO);
  const [selectedRec, setSelectedRec] = useState<string | null>(null);
  const [scaleText, setScaleText] = useState("");
  const [faceEnhance, setFaceEnhance] = useState(false);

  const [submitting, setSubmitting] = useState(false);
  const [job, setJob] = useState<UpscaleJobDTO | null>(null);
  const completedRef = useRef(onCompleted);
  completedRef.current = onCompleted;

  const refreshJob = useCallback(async (id: string) => {
    try {
      const j = await api.upscaleJob(id);
      setJob(j);
      if (j.status === "completed") completedRef.current?.();
    } catch {
      // ignore transient poll errors
    }
  }, []);

  useEffect(() => {
    api
      .upscaleModels()
      .then((list) => {
        setModels(list);
        const def = list.find((m) => m.installed && m.is_default);
        if (def) setModel(def.name);
      })
      .catch(() => toast("Impossible de charger les modèles d'upscaling", "error"));
    api
      .upscaleRecommendations({ image_id: item.id })
      .then((r) => {
        setRecs(r);
        setRecsLoaded(true);
        const best = r.find((x) => x.recommended) ?? r[0];
        if (best) setSelectedRec(`${best.width}x${best.height}`);
      })
      .catch(() => {
        setRecsLoaded(true);
        toast("Impossible de charger les résolutions recommandées", "error");
      });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [item.id]);

  // poll as a safety net alongside SSE
  useEffect(() => {
    if (!job || (job.status !== "queued" && job.status !== "running")) return;
    const id = job.id;
    const t = window.setInterval(() => void refreshJob(id), 3000);
    return () => window.clearInterval(t);
  }, [job, refreshJob]);

  useEvents(
    {
      upscaleStarted: (p) => {
        const e = p as { job_id: string };
        setJob((prev) => (prev && prev.id === e.job_id ? { ...prev, status: "running" } : prev));
      },
      upscaleProgress: (p) => {
        const e = p as {
          job_id: string;
          phase?: string;
          tiles_done?: number;
          tiles_total?: number;
        };
        setJob((prev) =>
          prev && prev.id === e.job_id
            ? {
                ...prev,
                status: "running",
                phase: e.phase,
                tiles_done: e.tiles_done,
                tiles_total: e.tiles_total,
              }
            : prev,
        );
      },
      upscaleCompleted: (p) => {
        const e = p as { job_id: string; output_path?: string };
        setJob((prev) =>
          prev && prev.id === e.job_id
            ? { ...prev, status: "completed", output_path: e.output_path }
            : prev,
        );
        completedRef.current?.();
      },
      upscaleFailed: (p) => {
        const e = p as { job_id: string; message: string };
        setJob((prev) => (prev && prev.id === e.job_id ? { ...prev, status: "failed" } : prev));
        toast(`Échec de l'upscaling : ${e.message}`, "error");
      },
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [],
  );

  const installedModels = (models ?? []).filter((m) => m.installed);
  const anyInstalled = installedModels.length > 0;
  const scaleValue = Number(scaleText);
  const customScaleValid =
    scaleText.trim() !== "" && Number.isFinite(scaleValue) && scaleValue >= 1.1 && scaleValue <= 8;
  const canLaunch =
    !submitting &&
    job === null &&
    anyInstalled &&
    (selectedRec !== null || customScaleValid);

  const pickRec = (key: string) => {
    setSelectedRec(key);
    setScaleText("");
  };

  const setCustomScale = (value: string) => {
    setScaleText(value);
    setSelectedRec(null);
  };

  const launch = async () => {
    if (!canLaunch) return;
    setSubmitting(true);
    try {
      const body: import("../types").UpscaleJobRequest = {
        image_id: item.id,
        model: model || undefined,
        face_enhance: faceEnhance || undefined,
      };
      if (selectedRec) {
        const [w, h] = selectedRec.split("x").map(Number);
        body.target_width = w;
        body.target_height = h;
      } else {
        body.scale = scaleValue;
      }
      const { job_id } = await api.createUpscaleJob(body);
      setJob({
        id: job_id,
        status: "queued",
        model: model || "auto",
        input_path: item.url,
        created_at: new Date().toISOString(),
      });
    } catch (err) {
      toast(err instanceof ApiError ? err.message : "Lancement impossible", "error");
    } finally {
      setSubmitting(false);
    }
  };

  const running = job?.status === "queued" || job?.status === "running";
  const tilesPct =
    job && job.tiles_total && (job.tiles_done ?? 0) > 0
      ? Math.min(100, ((job.tiles_done ?? 0) / job.tiles_total) * 100)
      : 0;

  return (
    <div className="modal-overlay" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="modal modal-wide" role="dialog" aria-modal="true" aria-label="Re-tirage grand format">
        <button className="modal-close" onClick={onClose} aria-label="Fermer">
          ✕
        </button>
        <p className="page-kicker">Agrandisseur</p>
        <h2 className="modal-title">Re-tirage grand format</h2>
        <p className="muted mono up-source">
          Source : {item.filename}
          {item.metadata?.width && item.metadata?.height
            ? ` (${item.metadata.width}×${item.metadata.height})`
            : ""}
        </p>

        {job && job.status === "completed" ? (
          <div className="up-done">
            <p className="up-done-title">Tirage terminé</p>
            <p className="muted">
              L'image agrandie a été ajoutée à la galerie (planche « Upscaled »).
            </p>
            <div className="up-done-actions">
              <Link className="btn btn-primary" to="/gallery?board=Upscaled" onClick={onClose}>
                Voir la planche « Upscaled »
              </Link>
              <button className="btn btn-ghost" onClick={onClose}>
                Fermer
              </button>
            </div>
          </div>
        ) : job && running ? (
          <div className="up-progress">
            <ProgressBar value={tilesPct} indeterminate={!job.tiles_total} />
            <p className="muted mono">
              {job.status === "queued"
                ? "En attente…"
                : `${job.phase ?? "Traitement"}${
                    job.tiles_total ? ` — tuiles ${job.tiles_done ?? 0}/${job.tiles_total}` : ""
                  }`}
            </p>
          </div>
        ) : (
          <>
            {models !== null && !anyInstalled && (
              <p className="hint up-hint">
                Aucun modèle d'upscaling installé. Téléchargez le modèle depuis l'app native.
              </p>
            )}

            <label className="field">
              <span>Modèle</span>
              <select value={model} onChange={(e) => setModel(e.target.value)}>
                <option value={AUTO}>Auto (par défaut)</option>
                {installedModels.map((m) => (
                  <option key={m.name} value={m.name}>
                    {m.display_name} (×{m.scale})
                  </option>
                ))}
              </select>
            </label>
            {models
              ?.filter((m) => !m.installed && !m.downloading)
              .slice(0, 1)
              .map((m) => (
                <p key={m.name} className="muted hint">
                  {m.display_name} n'est pas installé — Téléchargez le modèle depuis l'app native.
                </p>
              ))}

            <div className="field">
              <span>Format — résolution</span>
              {!recsLoaded && <p className="muted">Calcul des recommandations…</p>}
              {recsLoaded && recs && recs.length > 0 && (
                <div className="up-rec-grid">
                  {recs.map((r) => {
                    const key = `${r.width}x${r.height}`;
                    return (
                      <button
                        key={key}
                        type="button"
                        className={`up-rec-card ${selectedRec === key ? "selected" : ""} ${
                          r.recommended ? "recommended" : ""
                        }`}
                        onClick={() => pickRec(key)}
                      >
                        <span className="up-rec-label">
                          {r.label}
                        </span>
                        {r.recommended && <span className="up-rec-tag">recommandé</span>}
                        <span className="mono">
                          {r.width}×{r.height}
                        </span>
                        {r.note && <span className="up-rec-note">{r.note}</span>}
                      </button>
                    );
                  })}
                </div>
              )}
            </div>

            <div className="field-row">
              <label className="field">
                <span>Échelle personnalisée (1.1–8, alternative)</span>
                <input
                  type="number"
                  min={1.1}
                  max={8}
                  step={0.1}
                  placeholder="ex : 2"
                  value={scaleText}
                  onChange={(e) => setCustomScale(e.target.value)}
                  disabled={selectedRec !== null}
                />
              </label>
              <div className="field">
                <span>Amélioration des visages</span>
                <label className="up-toggle">
                  <input
                    type="checkbox"
                    checked={faceEnhance}
                    onChange={(e) => setFaceEnhance(e.target.checked)}
                  />
                  <span>face_enhance</span>
                </label>
              </div>
            </div>

            <button className="btn btn-primary btn-lg" type="button" disabled={!canLaunch} onClick={() => void launch()}>
              {submitting ? "Lancement…" : "Lancer"}
            </button>
            {job?.status === "failed" && job.error && (
              <p className="error-text">Échec : {job.error}</p>
            )}
          </>
        )}
      </div>
    </div>
  );
}

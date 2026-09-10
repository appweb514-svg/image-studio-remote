import { useCallback, useEffect, useRef, useState } from "react";
import { api, ApiError } from "../api";
import { useToast } from "../components/Toast";
import type { ModelRow, SystemStatus } from "../types";

// Modèles capables de rester résidents en RAM du worker (mode chaud).
// Le runner SDNQ n'a pas de mode résident : il est volontairement exclu.
const RESIDENT_MODELS = new Set([
  "flux2-klein-4b",
  "flux2-klein-4b-q8",
  "flux2-klein-4b-uncensored-q4",
  "flux2-klein-4b-uncensored-q8",
  "z-image-turbo",
]);

const POLL_INTERVAL_MS = 3000;
const POLL_MAX_MS = 60000;

type PendingAction = "load" | "unload";

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => window.setTimeout(resolve, ms));
}

export function ModelsPage() {
  const toast = useToast();
  const [models, setModels] = useState<ModelRow[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [llm, setLlm] = useState<SystemStatus["system"]["llm"]>(undefined);
  const [warmIds, setWarmIds] = useState<Set<string>>(new Set());
  const [pending, setPending] = useState<Record<string, PendingAction>>({});
  const [unloading, setUnloading] = useState(false);
  const mountedRef = useRef(true);

  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);

  const applyStatus = useCallback((s: SystemStatus) => {
    setLlm(s.system.llm);
    setWarmIds(new Set((s.system.warm_models ?? []).map((w) => w.id)));
  }, []);

  const refreshStatus = useCallback(async () => {
    try {
      applyStatus(await api.status());
    } catch {
      // Keep the previous badge state; the models table owns error reporting.
    }
  }, [applyStatus]);

  const refresh = useCallback(async () => {
    try {
      setModels(await api.models());
      setLoaded(true);
    } catch (err) {
      if (!(err instanceof ApiError && err.status === 401))
        toast("Impossible de charger les modèles", "error");
    }
    await refreshStatus();
  }, [toast, refreshStatus]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const waitForWarmState = useCallback(
    async (modelId: string, shouldBeResident: boolean): Promise<boolean> => {
      const deadline = Date.now() + POLL_MAX_MS;
      for (;;) {
        await sleep(POLL_INTERVAL_MS);
        if (!mountedRef.current) return false;
        try {
          const s = await api.status();
          if (!mountedRef.current) return false;
          applyStatus(s);
          const resident = (s.system.warm_models ?? []).some((w) => w.id === modelId);
          if (resident === shouldBeResident) return true;
        } catch {
          // Statut momentanément indisponible pendant le chargement : on réessaie.
        }
        if (Date.now() >= deadline) return false;
      }
    },
    [applyStatus],
  );

  const clearPending = useCallback((modelId: string) => {
    setPending((prev) => {
      if (!(modelId in prev)) return prev;
      const next = { ...prev };
      delete next[modelId];
      return next;
    });
  }, []);

  const loadModel = useCallback(
    async (m: ModelRow) => {
      setPending((prev) => ({ ...prev, [m.id]: "load" }));
      try {
        await api.loadModel(m.id);
      } catch (err) {
        if (mountedRef.current) {
          clearPending(m.id);
          if (!(err instanceof ApiError && err.status === 401))
            toast(err instanceof Error ? err.message : "Échec du chargement", "error");
        }
        return;
      }
      const ok = await waitForWarmState(m.id, true);
      if (!mountedRef.current) return;
      clearPending(m.id);
      if (ok) {
        toast(`${m.display_name} chargé en mémoire`, "success");
      } else {
        void refreshStatus();
        toast("Délai dépassé — vérifiez l'état du worker", "error");
      }
    },
    [toast, waitForWarmState, clearPending, refreshStatus],
  );

  const unloadModel = useCallback(
    async (m: ModelRow) => {
      setPending((prev) => ({ ...prev, [m.id]: "unload" }));
      try {
        await api.unloadModel(m.id);
      } catch (err) {
        if (mountedRef.current) {
          clearPending(m.id);
          if (!(err instanceof ApiError && err.status === 401))
            toast(err instanceof Error ? err.message : "Échec du déchargement", "error");
        }
        return;
      }
      const ok = await waitForWarmState(m.id, false);
      if (!mountedRef.current) return;
      clearPending(m.id);
      if (ok) {
        toast("Modèle déchargé", "success");
      } else {
        void refreshStatus();
        toast("Délai dépassé — vérifiez l'état du worker", "error");
      }
    },
    [toast, waitForWarmState, clearPending, refreshStatus],
  );

  const unloadLlm = useCallback(async () => {
    if (
      !window.confirm(
        "Libérer ~2,5 Go sur la mini ? Le prochain 'Prompt amélioré' rechargera le modèle (~10 s).",
      )
    )
      return;
    setUnloading(true);
    try {
      await api.unloadLlm();
      toast("Déchargement demandé", "success");
      window.setTimeout(() => {
        setUnloading(false);
        void refreshStatus();
      }, 4000);
    } catch (err) {
      setUnloading(false);
      if (!(err instanceof ApiError && err.status === 401))
        toast(err instanceof Error ? err.message : "Échec du déchargement", "error");
    }
  }, [toast, refreshStatus]);

  const busy = Object.keys(pending).length > 0;

  return (
    <div className="page">
      <div className="page-head">
        <div>
          <p className="page-kicker">Registre de l'atelier</p>
          <h1>Modèles</h1>
        </div>
        <button className="btn btn-ghost" onClick={() => void refresh()}>
          Rafraîchir
        </button>
      </div>
      <hr className="page-rule" />
      <p className="muted hint">
        Les téléchargements de modèles se font depuis l'application native MLXBits Image Studio.
      </p>
      <section className="card dash-card" aria-live="polite" style={{ marginBottom: 14 }}>
        <h2>Mémoire du worker</h2>
        {llm?.loaded ? (
          <div className="inline" style={{ justifyContent: "space-between", flexWrap: "wrap" }}>
            <span>
              <span className="charged-dot" aria-hidden="true" />
              LLM chargé{llm.model ? (
                <>
                  {" : "}
                  <span className="mono">{llm.model}</span>
                </>
              ) : null}
            </span>
            <button
              className="btn btn-chip btn-ghost btn-danger-text"
              onClick={() => void unloadLlm()}
              disabled={unloading}
            >
              {unloading ? "Déchargement…" : "Décharger"}
            </button>
          </div>
        ) : (
          <p className="muted" style={{ margin: 0 }}>
            Aucun modèle résident — mémoire libre
          </p>
        )}
        <p className="muted" style={{ margin: "8px 0 0", fontSize: "0.82rem" }}>
          Les modèles mflux sont chargés à chaque exécution, jamais résidents.
        </p>
      </section>
      {!loaded && (
        <div aria-busy="true">
          <p className="skeleton" style={{ height: 220 }} />
        </div>
      )}
      {loaded && models.length === 0 && (
        <div className="empty-state">
          <h2>Aucun modèle au registre</h2>
          <hr className="rule" />
          <p>Chargez un modèle depuis l'application native pour ouvrir l'atelier.</p>
        </div>
      )}
      {loaded && models.length > 0 && (
        <>
          <p className="muted hint">
            Un seul modèle résident à la fois — charger un modèle décharge le précédent.
          </p>
          <div className="table-wrap card">
            <table>
              <thead>
                <tr>
                  <th>Nom</th>
                  <th>Famille</th>
                  <th>Installé</th>
                  <th>Taille Q8</th>
                  <th>Taille Q4</th>
                  <th>Dépôt</th>
                  <th>Mémoire</th>
                </tr>
              </thead>
              <tbody>
                {models.map((m) => {
                  const supportsResident = RESIDENT_MODELS.has(m.id);
                  const resident = warmIds.has(m.id);
                  const action = pending[m.id];
                  return (
                    <tr key={m.id}>
                      <td>{m.display_name}</td>
                      <td>{m.family}</td>
                      <td>
                        {(m.on_disk_q8 || m.on_disk_q4) && (
                          <span>
                            <span className="charged-dot" aria-hidden />
                            chargé
                          </span>
                        )}
                        {m.on_disk_q8 && <span className="badge badge-q8">Q8</span>}
                        {m.on_disk_q4 && <span className="badge badge-q4">Q4</span>}
                        {!m.on_disk_q8 && !m.on_disk_q4 && <span className="muted">—</span>}
                      </td>
                      <td>{m.size_gb_q8 != null ? `${m.size_gb_q8.toFixed(1)} Go` : "—"}</td>
                      <td>{m.size_gb_q4 != null ? `${m.size_gb_q4.toFixed(1)} Go` : "—"}</td>
                      <td>
                        {m.repo_url ? (
                          <a href={m.repo_url} target="_blank" rel="noreferrer">
                            Hugging Face ↗
                          </a>
                        ) : (
                          <span className="muted">—</span>
                        )}
                      </td>
                      <td>
                        {!supportsResident ? (
                          <span className="muted">—</span>
                        ) : resident ? (
                          <span className="mem-cell">
                            <span className="mem-status" aria-live="polite">
                              <span className="charged-dot" aria-hidden="true" />
                              En mémoire
                            </span>
                            <button
                              className="btn btn-chip btn-ghost btn-danger-text"
                              onClick={() => void unloadModel(m)}
                              disabled={busy}
                            >
                              {action === "unload" ? (
                                <>
                                  <span className="spinner" aria-hidden="true" />
                                  Déchargement…
                                </>
                              ) : (
                                "Décharger"
                              )}
                            </button>
                          </span>
                        ) : (
                          <button
                            className="btn btn-chip"
                            onClick={() => void loadModel(m)}
                            disabled={busy}
                          >
                            {action === "load" ? (
                              <>
                                <span className="spinner" aria-hidden="true" />
                                Chargement…
                              </>
                            ) : (
                              "Charger"
                            )}
                          </button>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </>
      )}
    </div>
  );
}

import { useCallback, useEffect, useState } from "react";
import { api, ApiError } from "../api";
import { useToast } from "../components/Toast";
import type { ModelRow, SystemStatus } from "../types";

export function ModelsPage() {
  const toast = useToast();
  const [models, setModels] = useState<ModelRow[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [llm, setLlm] = useState<SystemStatus["system"]["llm"]>(undefined);
  const [unloading, setUnloading] = useState(false);

  const refreshStatus = useCallback(async () => {
    try {
      const s = await api.status();
      setLlm(s.system.llm);
    } catch {
      // Keep the previous badge state; the models table owns error reporting.
    }
  }, []);

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
              </tr>
            </thead>
            <tbody>
              {models.map((m) => (
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
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

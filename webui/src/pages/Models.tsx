import { useCallback, useEffect, useState } from "react";
import { api, ApiError } from "../api";
import { useToast } from "../components/Toast";
import type { ModelRow } from "../types";

export function ModelsPage() {
  const toast = useToast();
  const [models, setModels] = useState<ModelRow[]>([]);
  const [loaded, setLoaded] = useState(false);

  const refresh = useCallback(async () => {
    try {
      setModels(await api.models());
      setLoaded(true);
    } catch (err) {
      if (!(err instanceof ApiError && err.status === 401))
        toast("Impossible de charger les modèles", "error");
    }
  }, [toast]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  return (
    <div className="page">
      <div className="page-head">
        <h1>Modèles</h1>
        <button className="btn btn-ghost" onClick={() => void refresh()}>
          Rafraîchir
        </button>
      </div>
      <p className="muted hint">
        💡 Les téléchargements de modèles se font depuis l'application native MLXBits Image Studio.
      </p>
      {!loaded && <p className="muted">Chargement…</p>}
      {loaded && models.length === 0 && <p className="muted">Aucun modèle référencé.</p>}
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

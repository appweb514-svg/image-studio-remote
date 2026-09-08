import { useCallback, useEffect, useMemo, useState, type CSSProperties } from "react";
import { useSearchParams } from "react-router-dom";
import { api, ApiError } from "../api";
import { useEvents } from "../sse";
import { useToast } from "../components/Toast";
import { UpscaleModal } from "../components/UpscaleModal";
import type { Flag, GalleryItemDTO } from "../types";

type FlagFilter = "all" | "pick" | "reject" | "unflagged";

function formatDate(iso: string): string {
  try {
    return new Date(iso).toLocaleString("fr-FR");
  } catch {
    return iso;
  }
}

export function GalleryPage() {
  const toast = useToast();
  const [items, setItems] = useState<GalleryItemDTO[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [familyFilter, setFamilyFilter] = useState("all");
  const [flagFilter, setFlagFilter] = useState<FlagFilter>("all");
  const [viewerIndex, setViewerIndex] = useState<number | null>(null);
  const [zoom, setZoom] = useState(1);
  const [upscaleItem, setUpscaleItem] = useState<GalleryItemDTO | null>(null);
  const [searchParams, setSearchParams] = useSearchParams();
  const [boardFilter, setBoardFilter] = useState<string>("all");

  // deep link ?board=<name> (e.g. from the UpScaler "Terminé" toast)
  useEffect(() => {
    const b = searchParams.get("board");
    if (b) {
      setBoardFilter(b);
      setSearchParams({}, { replace: true });
    }
  }, [searchParams, setSearchParams]);

  const refresh = useCallback(async () => {
    try {
      setItems(await api.history());
      setLoaded(true);
    } catch (err) {
      if (!(err instanceof ApiError && err.status === 401))
        toast("Impossible de charger la galerie", "error");
    }
  }, [toast]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  // galleryChanged is not part of the SSE contract; refresh when jobs complete.
  useEvents(
    {
      jobCompleted: () => void refresh(),
      upscaleCompleted: () => void refresh(),
    },
    [refresh],
  );

  const families = useMemo(
    () => Array.from(new Set(items.map((i) => i.family))).sort(),
    [items],
  );

  const boards = useMemo(
    () =>
      Array.from(new Set(items.map((i) => i.board).filter((b): b is string => !!b))).sort(),
    [items],
  );

  const filtered = useMemo(
    () =>
      items.filter((i) => {
        if (familyFilter !== "all" && i.family !== familyFilter) return false;
        if (boardFilter !== "all" && (i.board ?? "") !== boardFilter) return false;
        if (flagFilter === "pick" && i.flag !== "pick") return false;
        if (flagFilter === "reject" && i.flag !== "reject") return false;
        if (flagFilter === "unflagged" && i.flag) return false;
        return true;
      }),
    [items, familyFilter, boardFilter, flagFilter],
  );

  const current = viewerIndex !== null ? filtered[viewerIndex] : undefined;

  const closeViewer = () => {
    setViewerIndex(null);
    setZoom(1);
  };
  const step = useCallback(
    (delta: number) => {
      setViewerIndex((i) => {
        if (i === null) return i;
        const next = (i + delta + filtered.length) % filtered.length;
        return next;
      });
      setZoom(1);
    },
    [filtered.length],
  );

  useEffect(() => {
    if (viewerIndex === null) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") closeViewer();
      if (e.key === "ArrowLeft") step(-1);
      if (e.key === "ArrowRight") step(1);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [viewerIndex, step]);

  const updateItem = (id: string, patch: Partial<GalleryItemDTO>) =>
    setItems((prev) => prev.map((i) => (i.id === id ? { ...i, ...patch } : i)));

  const doFlag = async (item: GalleryItemDTO, flag: Flag) => {
    const next = item.flag === flag ? null : flag;
    try {
      await api.setFlag(item.id, next);
      updateItem(item.id, { flag: next ?? undefined });
    } catch {
      toast("Impossible de changer le marqueur", "error");
    }
  };

  const doRate = async (item: GalleryItemDTO, rating: number) => {
    const next = item.rating === rating ? 0 : rating;
    try {
      await api.setRating(item.id, next);
      updateItem(item.id, { rating: next });
    } catch {
      toast("Impossible de changer la note", "error");
    }
  };

  const doAction = async (item: GalleryItemDTO, action: "reuse" | "variation") => {
    try {
      if (action === "reuse") await api.reuse(item.id);
      else await api.variation(item.id);
      toast(action === "reuse" ? "Réglages réutilisés — génération lancée" : "Variation lancée", "success");
    } catch (err) {
      toast(err instanceof ApiError ? err.message : "Action impossible", "error");
    }
  };

  const copyPrompt = async (text?: string) => {
    if (!text) return;
    try {
      await navigator.clipboard.writeText(text);
      toast("Prompt copié", "success");
    } catch {
      toast("Copie impossible", "error");
    }
  };

  return (
    <div className="page">
      <div className="page-head">
        <div>
          <p className="page-kicker">Planches contact</p>
          <h1>Galerie</h1>
        </div>
      </div>
      <hr className="page-rule" />
      <div className="filter-bar">
        <label className="field">
          <span>Famille</span>
          <select value={familyFilter} onChange={(e) => setFamilyFilter(e.target.value)}>
            <option value="all">Toutes</option>
            {families.map((f) => (
              <option key={f} value={f}>
                {f}
              </option>
            ))}
          </select>
        </label>
        <label className="field">
          <span>Planche</span>
          <select value={boardFilter} onChange={(e) => setBoardFilter(e.target.value)}>
            <option value="all">Toutes</option>
            {boards.map((b) => (
              <option key={b} value={b}>
                {b}
              </option>
            ))}
          </select>
        </label>
        <label className="field">
          <span>Marqueur</span>
          <select value={flagFilter} onChange={(e) => setFlagFilter(e.target.value as FlagFilter)}>
            <option value="all">Tous</option>
            <option value="pick">Sélection</option>
            <option value="reject">Rejetés</option>
            <option value="unflagged">Non marqués</option>
          </select>
        </label>
      </div>

      {!loaded && (
        <div aria-busy="true">
          <p className="skeleton" style={{ height: 180 }} />
        </div>
      )}
      {loaded && filtered.length === 0 && (
        <div className="empty-state">
          <h2>Aucune épreuve à voir</h2>
          <hr className="rule" />
          <p>La planche est encore vierge — vos tirages y seront épinglés.</p>
        </div>
      )}

      <div className="gallery-grid">
        {filtered.map((item, i) => (
          <button
            key={item.id}
            className="gallery-item"
            style={{ "--i": Math.min(i, 14) } as CSSProperties}
            onClick={() => {
              setViewerIndex(i);
              setZoom(1);
            }}
          >
            <img
              src={item.thumbnail_url}
              alt={item.filename}
              loading="lazy"
            />
            <span className="contact-caption" aria-hidden>
              <p>{item.metadata?.prompt ?? item.filename}</p>
              <span>
                {item.metadata?.seed !== undefined ? `SEED ${item.metadata.seed}` : "SEED —"}
                {item.metadata?.width && item.metadata?.height
                  ? ` · ${item.metadata.width}×${item.metadata.height}`
                  : ""}
                {item.metadata?.steps ? ` · ${item.metadata.steps} POSES` : ""}
              </span>
            </span>
            {item.flag && (
              <span className={`flag-corner flag-${item.flag}`}>
                {item.flag === "pick" ? "✓" : "✕"}
              </span>
            )}
            {item.rating > 0 && <span className="rating-corner">{"★".repeat(item.rating)}</span>}
          </button>
        ))}
      </div>

      {current && (
        <div className="viewer" role="dialog" aria-modal="true">
          <div
            className="viewer-stage"
            onWheel={(e) => {
              e.preventDefault();
              setZoom((z) => Math.min(8, Math.max(1, z - Math.sign(e.deltaY) * 0.25)));
            }}
            onTouchMove={(e) => {
              // crude two-finger pinch zoom
              if (e.touches.length === 2) {
                const dx = e.touches[0].clientX - e.touches[1].clientX;
                const dy = e.touches[0].clientY - e.touches[1].clientY;
                const dist = Math.hypot(dx, dy);
                setZoom(Math.min(8, Math.max(1, dist / 200)));
              }
            }}
          >
            <img
              src={current.url}
              alt={current.filename}
              style={{ transform: `scale(${zoom})` }}
            />
          </div>
          <button className="viewer-nav viewer-prev" onClick={() => step(-1)} aria-label="Précédente">
            ‹
          </button>
          <button className="viewer-nav viewer-next" onClick={() => step(1)} aria-label="Suivante">
            ›
          </button>
          <button className="viewer-close" onClick={closeViewer} aria-label="Fermer">
            ✕
          </button>
          <span className="light-table-count" aria-hidden>
            ÉPREUVE Nº {(viewerIndex ?? 0) + 1} / {filtered.length}
          </span>
          <div className="light-table-strip" aria-label="Épreuves voisines">
            {filtered.map((n, ni) => (
              <button
                key={n.id}
                type="button"
                className={ni === viewerIndex ? "current" : ""}
                onClick={() => {
                  setViewerIndex(ni);
                  setZoom(1);
                }}
                aria-label={`Voir ${n.filename}`}
                aria-current={ni === viewerIndex}
              >
                <img src={n.thumbnail_url} alt="" loading="lazy" />
              </button>
            ))}
          </div>
          <aside className="viewer-detail">
            <p className="micro-label">Fiche d'épreuve</p>
            <h3 className="mono">{current.filename}</h3>
            <p className="muted">{formatDate(current.modified_at)}</p>
            {current.board && <p className="muted">Planche — {current.board}</p>}
            {current.metadata?.prompt && <p className="detail-prompt">{current.metadata.prompt}</p>}
            {current.metadata?.negative_prompt && (
              <p className="muted detail-prompt">Négatif : {current.metadata.negative_prompt}</p>
            )}
            <dl className="detail-grid">
              {current.metadata?.model && (
                <>
                  <dt>Modèle</dt>
                  <dd>{current.metadata.model}</dd>
                </>
              )}
              {current.metadata?.seed !== undefined && (
                <>
                  <dt>Seed</dt>
                  <dd className="mono">{current.metadata.seed}</dd>
                </>
              )}
              {current.metadata?.steps !== undefined && (
                <>
                  <dt>Étapes</dt>
                  <dd>{current.metadata.steps}</dd>
                </>
              )}
              {current.metadata?.guidance !== undefined && (
                <>
                  <dt>Guidance</dt>
                  <dd>{current.metadata.guidance}</dd>
                </>
              )}
              {current.metadata?.width !== undefined && current.metadata?.height !== undefined && (
                <>
                  <dt>Taille</dt>
                  <dd>
                    {current.metadata.width}×{current.metadata.height}
                  </dd>
                </>
              )}
              {current.metadata?.quantize !== undefined && (
                <>
                  <dt>Quant.</dt>
                  <dd>{current.metadata.quantize} bit</dd>
                </>
              )}
              {current.metadata?.loras?.length ? (
                <>
                  <dt>LoRAs</dt>
                  <dd>{current.metadata.loras.join(", ")}</dd>
                </>
              ) : null}
            </dl>
            <div className="detail-actions">
              <button className="btn btn-chip" onClick={() => void doAction(current, "reuse")}>
                Réutiliser les réglages
              </button>
              <button className="btn btn-chip" onClick={() => void doAction(current, "variation")}>
                Générer une variation
              </button>
              <button className="btn btn-chip" onClick={() => void copyPrompt(current.metadata?.prompt)}>
                Copier le prompt
              </button>
              <button className="btn btn-chip" onClick={() => setUpscaleItem(current)}>
                Re-tirage grand format
              </button>
              <a className="btn btn-chip" href={current.url} download={current.filename}>
                Télécharger
              </a>
            </div>
            <div className="detail-row">
              <button
                className={`btn btn-chip ${current.flag === "pick" ? "flagged-pick" : ""}`}
                onClick={() => void doFlag(current, "pick")}
              >
                ✓ Sélection
              </button>
              <button
                className={`btn btn-chip ${current.flag === "reject" ? "flagged-reject" : ""}`}
                onClick={() => void doFlag(current, "reject")}
              >
                ✕ Rejet
              </button>
            </div>
            <div className="detail-row stars" role="radiogroup" aria-label="Note">
              {[1, 2, 3, 4, 5].map((n) => (
                <button
                  key={n}
                  className={`star ${current.rating >= n ? "star-on" : ""}`}
                  onClick={() => void doRate(current, n)}
                  aria-label={`${n} étoiles`}
                >
                  ★
                </button>
              ))}
            </div>
          </aside>
        </div>
      )}

      {upscaleItem && (
        <UpscaleModal
          item={upscaleItem}
          onClose={() => setUpscaleItem(null)}
          onCompleted={() => void refresh()}
        />
      )}
    </div>
  );
}

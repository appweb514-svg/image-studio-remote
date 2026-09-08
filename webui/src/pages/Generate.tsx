import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from "react";
import { api, ApiError } from "../api";
import { useEvents } from "../sse";
import { useToast } from "../components/Toast";
import { ProgressBar } from "../components/ProgressBar";
import { Particles } from "../components/Aurora";
import type { Capabilities, GenerateRequest, ModelInfo, Presets } from "../types";

const TARGET_MPS = [0.25, 0.5, 1.0];
const RATIO_LABELS = ["1:1", "3:2", "2:3", "16:9", "9:16"] as const;
const RATIOS: Record<(typeof RATIO_LABELS)[number], number> = {
  "1:1": 1,
  "3:2": 3 / 2,
  "2:3": 2 / 3,
  "16:9": 16 / 9,
  "9:16": 9 / 16,
};

interface LiveJob {
  id: string;
  totalSteps: number;
  step: number;
  statusLine?: string;
  startedAt: number;
  previewSrc?: string;
  previewPrev?: string;
}

function roundTo(value: number, multiple: number): number {
  return Math.max(multiple, Math.round(value / multiple) * multiple);
}

function computeDims(mp: number, ratio: number, c: Capabilities): { w: number; h: number } {
  const { min_edge, max_edge, multiple_of } = c.dimension_constraints;
  const area = mp * 1_000_000;
  let w = Math.sqrt(area * ratio);
  let h = w / ratio;
  w = roundTo(w, multiple_of);
  h = roundTo(h, multiple_of);
  w = Math.min(max_edge, Math.max(min_edge, w));
  h = Math.min(max_edge, Math.max(min_edge, h));
  return { w, h };
}

/** Client-side resize to max 2048px on the longest edge, returns base64 JPEG. */
async function resizeImage(
  file: File,
  maxEdge = 2048,
): Promise<{ base64: string; mime: string; naturalWidth: number; naturalHeight: number }> {
  const bitmap = await createImageBitmap(file);
  const scale = Math.min(1, maxEdge / Math.max(bitmap.width, bitmap.height));
  const naturalWidth = bitmap.width;
  const naturalHeight = bitmap.height;
  const w = Math.round(bitmap.width * scale);
  const h = Math.round(bitmap.height * scale);
  const canvas = document.createElement("canvas");
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext("2d");
  if (!ctx) throw new Error("Canvas indisponible");
  ctx.drawImage(bitmap, 0, 0, w, h);
  bitmap.close();
  const mime = "image/jpeg";
  const dataUrl = canvas.toDataURL(mime, 0.9);
  return { base64: dataUrl.slice(dataUrl.indexOf(",") + 1), mime, naturalWidth, naturalHeight };
}

interface EditImage {
  base64: string;
  filename: string;
  path: string | null;
}

export function GeneratePage() {
  const toast = useToast();
  const [caps, setCaps] = useState<Capabilities | null>(null);
  const [presets, setPresets] = useState<Presets | null>(null);

  // form state
  const [family, setFamily] = useState<string>("");
  const [modelId, setModelId] = useState<string>("");
  const [customRepo, setCustomRepo] = useState("");
  const [prompt, setPrompt] = useState("");
  const [negativePrompt, setNegativePrompt] = useState("");
  const [width, setWidth] = useState(1024);
  const [height, setHeight] = useState(1024);
  const [steps, setSteps] = useState(20);
  const [guidance, setGuidance] = useState(3.5);
  const [seedText, setSeedText] = useState("");
  const [batch, setBatch] = useState(1);
  const [quantize, setQuantize] = useState<number | null>(null);
  const [board, setBoard] = useState("");
  const [loras, setLoras] = useState<{ path: string; strength: number }[]>([]);
  const [imageBase64, setImageBase64] = useState<{ base64: string; filename: string } | null>(null);
  const [imagePath, setImagePath] = useState<string | null>(null);
  const [imageStrength, setImageStrength] = useState(0.6);
  const [mode, setMode] = useState<"generate" | "edit">("generate");
  const [editImages, setEditImages] = useState<EditImage[]>([]);
  const editFileInputRef = useRef<HTMLInputElement | null>(null);

  const [targetMp, setTargetMp] = useState(1.0);
  const [submitting, setSubmitting] = useState(false);

  // live job card
  const [live, setLive] = useState<LiveJob | null>(null);
  const [resultSrc, setResultSrc] = useState<string | null>(null);
  const liveIdRef = useRef<string | null>(null);

  useEffect(() => {
    Promise.all([api.capabilities(), api.presets()])
      .then(([c, p]) => {
        setCaps(c);
        setPresets(p);
        const fam = c.families.find((f) => f.web_enqueue);
        if (fam) setFamily(fam.id);
        const firstModel = c.models.find((m) => fam && m.family === fam.id);
        if (firstModel) {
          setModelId(firstModel.id);
          setSteps(firstModel.default_steps);
          setGuidance(firstModel.default_guidance);
          setQuantize(firstModel.recommended_quantize);
        }
      })
      .catch(() => toast("Impossible de charger les capacités", "error"));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const enabledFamilies = useMemo(() => caps?.families.filter((f) => f.web_enqueue) ?? [], [caps]);
  const selectedFamily = useMemo(
    () => caps?.families.find((f) => f.id === family),
    [caps, family],
  );
  const supportsEdit = selectedFamily?.supports_edit ?? false;
  const maxEditImages = selectedFamily?.max_edit_images ?? 4;
  const isEdit = supportsEdit && mode === "edit";
  const modelsForFamily = useMemo(
    () => caps?.models.filter((m) => m.family === family) ?? [],
    [caps, family],
  );
  const selectedModel: ModelInfo | undefined = useMemo(
    () => caps?.models.find((m) => m.id === modelId),
    [caps, modelId],
  );

  // apply model defaults + presets when switching model
  const applyModelDefaults = (id: string) => {
    setModelId(id);
    const m = caps?.models.find((x) => x.id === id);
    if (!m) return;
    const def = presets?.model_defaults.find((d) => d.model === id);
    setSteps(def?.steps ?? m.default_steps);
    setGuidance(def?.guidance ?? m.default_guidance);
    if (def?.width && def?.height) {
      setWidth(def.width);
      setHeight(def.height);
    }
    setQuantize(def?.quantize ?? m.recommended_quantize);
    if (!m.supports_negative_prompt) setNegativePrompt("");
  };

  // dims follow ratio/mp preset only while user hasn't overridden via inputs
  const applyRatio = (label: (typeof RATIO_LABELS)[number]) => {
    if (!caps) return;
    const { w, h } = computeDims(targetMp, RATIOS[label], caps);
    setWidth(w);
    setHeight(h);
  };

  const setDims = (w: number, h: number) => {
    if (!caps) return;
    const { min_edge, max_edge, multiple_of } = caps.dimension_constraints;
    setWidth(roundTo(Math.min(max_edge, Math.max(min_edge, w || min_edge)), multiple_of));
    setHeight(roundTo(Math.min(max_edge, Math.max(min_edge, h || min_edge)), multiple_of));
  };

  const onPickImage = async (file: File | undefined) => {
    if (!file) return;
    try {
      const { base64 } = await resizeImage(file);
      setImageBase64({ base64, filename: file.name });
    } catch {
      toast("Impossible de lire l'image", "error");
    }
  };

  const onPickEditImages = async (files: FileList | undefined | null) => {
    if (!files || files.length === 0) return;
    const room = maxEditImages - editImages.length;
    const picked = Array.from(files).slice(0, Math.max(0, room));
    if (picked.length < files.length) {
      toast(`Maximum ${maxEditImages} images en mode édition`, "error");
    }
    const isFirst = editImages.length === 0;
    const added: EditImage[] = [];
    for (const file of picked) {
      try {
        const { base64, naturalWidth, naturalHeight } = await resizeImage(file);
        if (isFirst && added.length === 0) setDims(naturalWidth, naturalHeight);
        added.push({ base64, filename: file.name, path: null });
      } catch {
        toast("Impossible de lire l'image", "error");
      }
    }
    if (added.length) setEditImages((prev) => [...prev, ...added].slice(0, maxEditImages));
  };

  const moveEditImage = (index: number, dir: -1 | 1) => {
    setEditImages((prev) => {
      const j = index + dir;
      if (j < 0 || j >= prev.length) return prev;
      const next = [...prev];
      [next[index], next[j]] = [next[j], next[index]];
      return next;
    });
  };

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (!caps || submitting) return;
    setSubmitting(true);
    try {
      const body: GenerateRequest = {
        family: family || undefined,
        model: modelId || undefined,
        custom_repo: customRepo.trim() || undefined,
        prompt,
        width,
        height,
        steps,
        guidance,
        seed: seedText.trim() === "" ? null : Number(seedText.trim()),
        quantize: quantize ?? undefined,
        board: board.trim() || undefined,
        loras: loras.filter((l) => l.path.trim()).length
          ? loras
              .filter((l) => l.path.trim())
              .map((l) => ({ path: l.path.trim(), strength: l.strength, enabled: true }))
          : undefined,
      };

      if (isEdit) {
        const paths: string[] = [];
        for (const img of editImages) {
          if (img.path) {
            paths.push(img.path);
            continue;
          }
          const { path } = await api.upload(img.filename, "image/jpeg", img.base64);
          paths.push(path);
          setEditImages((prev) =>
            prev.map((x) => (x.filename === img.filename && x.base64 === img.base64 ? { ...x, path } : x)),
          );
        }
        body.edit_mode = true;
        body.edit_image_paths = paths;
        body.batch = 1;
      } else {
        let finalImagePath = imagePath;
        if (imageBase64 && !finalImagePath) {
          const { path } = await api.upload(imageBase64.filename, "image/jpeg", imageBase64.base64);
          finalImagePath = path;
          setImagePath(path);
        }
        body.negative_prompt =
          selectedModel?.supports_negative_prompt && negativePrompt.trim()
            ? negativePrompt.trim()
            : undefined;
        body.batch = Math.max(caps.batch_limits.min, Math.min(caps.batch_limits.max, batch));
        body.image_path = finalImagePath ?? undefined;
        body.image_strength = finalImagePath ? imageStrength : undefined;
      }

      await api.generate(body);
      toast(isEdit ? "Édition envoyée" : "Génération envoyée", "success");
    } catch (err) {
      toast(err instanceof ApiError ? err.message : "Échec de l'envoi", "error");
    } finally {
      setSubmitting(false);
    }
  };

  // SSE: track the newest running job for the live card
  useEvents(
    {
      jobCreated: (p) => {
        const e = p as { job_id: string };
        liveIdRef.current = e.job_id;
        setLive({ id: e.job_id, totalSteps: 0, step: 0, startedAt: Date.now() });
        setResultSrc(null);
      },
      jobStarted: (p) => {
        const e = p as { job_id: string; total_steps: number };
        setLive((prev) =>
          prev && prev.id === e.job_id ? { ...prev, totalSteps: e.total_steps } : prev,
        );
      },
      jobProgress: (p) => {
        const e = p as { job_id: string; step: number; total_steps: number; status_line?: string };
        setLive((prev) =>
          prev && prev.id === e.job_id
            ? { ...prev, step: e.step, totalSteps: e.total_steps, statusLine: e.status_line }
            : prev,
        );
      },
      jobPreview: (p) => {
        const e = p as { job_id: string; jpeg_base64: string };
        setLive((prev) =>
          prev && prev.id === e.job_id
            ? {
                ...prev,
                previewPrev: prev.previewSrc,
                previewSrc: `data:image/jpeg;base64,${e.jpeg_base64}`,
              }
            : prev,
        );
      },
      jobCompleted: (p) => {
        const e = p as { job_id: string };
        setLive((prev) => (prev && prev.id === e.job_id ? null : prev));
        setResultSrc(`/api/v1/jobs/${encodeURIComponent(e.job_id)}/preview?${Date.now()}`);
        toast("Tirage terminé", "success");
      },
      jobFailed: (p) => {
        const e = p as { job_id: string; message: string };
        setLive((prev) => (prev && prev.id === e.job_id ? null : prev));
        toast(`Échec : ${e.message}`, "error");
      },
      jobCancelled: (p) => {
        const e = p as { job_id: string };
        if (liveIdRef.current === e.job_id) {
          toast("Génération annulée", "info");
          setLive(null);
        }
      },
      modelLoading: (p) => toast(`Chargement du modèle : ${(p as { label: string }).label}`, "info"),
      modelLoaded: (p) =>
        toast(`Modèle prêt : ${(p as { label: string }).label}`, "success"),
      downloadProgress: (p) =>
        toast((p as { message: string }).message, "info"),
    },
    [],
  );

  const elapsed = live ? Math.max(0, Math.round((Date.now() - live.startedAt) / 1000)) : 0;
  const [, forceTick] = useState(0);
  useEffect(() => {
    if (!live) return;
    const t = window.setInterval(() => forceTick((n) => n + 1), 1000);
    return () => window.clearInterval(t);
  }, [live]);

  const cancelLive = useCallback(async () => {
    if (!live) return;
    try {
      await api.cancelJob(live.id);
      toast("Annulation demandée", "info");
    } catch {
      toast("Annulation impossible", "error");
    }
  }, [live, toast]);

  const mp = ((width * height) / 1_000_000).toFixed(2);
  const estSeconds = selectedModel ? Math.round((steps * (width * height)) / 1e6 * 1.2) : null;

  return (
    <div className="page">
      <p className="page-kicker">Banc d'agrandissement</p>
      <h1>Générer</h1>
      <hr className="page-rule" />
      <div className="generate-grid">
        <form className="card glass form" onSubmit={submit}>
          <h2 className="bench-section-title">Négatif — source &amp; paramètres</h2>
          <p className="bench-sub">Préparez la plaque, réglez la lumière.</p>
          {supportsEdit && (
            <div className="segmented" role="group" aria-label="Mode">
              <button
                type="button"
                className={mode === "generate" ? "active" : ""}
                onClick={() => setMode("generate")}
              >
                Générer
              </button>
              <button
                type="button"
                className={mode === "edit" ? "active" : ""}
                onClick={() => setMode("edit")}
              >
                Éditer
              </button>
            </div>
          )}

          <label className="field">
            <span>Famille</span>
            <select value={family} onChange={(e) => {
              setFamily(e.target.value);
              const first = caps?.models.find((m) => m.family === e.target.value);
              if (first) applyModelDefaults(first.id);
            }}>
              {enabledFamilies.map((f) => (
                <option key={f.id} value={f.id}>
                  {f.display_name}
                </option>
              ))}
            </select>
          </label>

          <label className="field">
            <span>Modèle</span>
            <select value={modelId} onChange={(e) => applyModelDefaults(e.target.value)}>
              {modelsForFamily.map((m) => (
                <option key={m.id} value={m.id}>
                  {m.display_name}
                  {m.is_distilled ? " (distillé)" : ""}
                </option>
              ))}
            </select>
          </label>

          <label className="field">
            <span>Dépôt custom (optionnel, HF repo id)</span>
            <input
              type="text"
              placeholder="ex : black-forest-labs/FLUX.1-schnell"
              value={customRepo}
              onChange={(e) => setCustomRepo(e.target.value)}
            />
          </label>

          <label className="field">
            <span>{isEdit ? "Instruction" : "Prompt"}</span>
            <textarea
              rows={4}
              required
              value={prompt}
              onChange={(e) => setPrompt(e.target.value)}
              placeholder={
                isEdit
                  ? "Changez l'angle de vue du portrait vers une vue de trois-quarts"
                  : "Décrivez l'image souhaitée…"
              }
            />
          </label>

          {presets && presets.templates.length > 0 && (
            <label className="field">
              <span>Gabarits</span>
              <select
                value=""
                onChange={(e) => {
                  const t = presets.templates.find((x) => x.id === e.target.value);
                  if (t) {
                    setPrompt(t.positive);
                    if (t.negative) setNegativePrompt(t.negative);
                  }
                }}
              >
                <option value="">— Choisir un gabarit —</option>
                {presets.templates.map((t) => (
                  <option key={t.id} value={t.id}>
                    {t.name}
                  </option>
                ))}
              </select>
            </label>
          )}

          {selectedModel?.supports_negative_prompt && !isEdit && (
            <label className="field">
              <span>Prompt négatif</span>
              <textarea
                rows={2}
                value={negativePrompt}
                onChange={(e) => setNegativePrompt(e.target.value)}
                placeholder="Ce que vous ne voulez pas voir…"
              />
            </label>
          )}

          <div className="field-row">
            <div className="field">
              <span>Format — dimensions (L × H)</span>
              <div className="inline">
                <input
                  type="number"
                  value={width}
                  min={caps?.dimension_constraints.min_edge}
                  max={caps?.dimension_constraints.max_edge}
                  step={caps?.dimension_constraints.multiple_of}
                  onChange={(e) => setDims(Number(e.target.value), height)}
                  style={{ width: 90 }}
                />
                <span>×</span>
                <input
                  type="number"
                  value={height}
                  min={caps?.dimension_constraints.min_edge}
                  max={caps?.dimension_constraints.max_edge}
                  step={caps?.dimension_constraints.multiple_of}
                  onChange={(e) => setDims(width, Number(e.target.value))}
                  style={{ width: 90 }}
                />
              </div>
            </div>
            <div className="field">
              <span>Définition</span>
              <select value={targetMp} onChange={(e) => setTargetMp(Number(e.target.value))}>
                {TARGET_MPS.map((mpv) => (
                  <option key={mpv} value={mpv}>
                    ≈ {mpv} Mpx
                  </option>
                ))}
              </select>
            </div>
          </div>

          <div className="ratio-row">
            {RATIO_LABELS.map((label) => (
              <button
                key={label}
                type="button"
                className="btn btn-chip"
                onClick={() => applyRatio(label)}
              >
                {label}
              </button>
            ))}
          </div>

          <div className="field-row">
            <label className="field">
              <span>Étapes</span>
              <input
                type="number"
                min={1}
                max={100}
                value={steps}
                onChange={(e) => setSteps(Math.max(1, Number(e.target.value)))}
              />
            </label>
            <label className="field">
              <span>Guidance</span>
              <input
                type="number"
                min={0}
                max={20}
                step={0.1}
                value={guidance}
                onChange={(e) => setGuidance(Number(e.target.value))}
              />
            </label>
          </div>

          <div className="field-row">
            <label className="field">
              <span>Seed (vide = aléatoire)</span>
              <div className="inline">
                <input
                  type="text"
                  inputMode="numeric"
                  value={seedText}
                  onChange={(e) => setSeedText(e.target.value.replace(/[^\d]/g, ""))}
                  placeholder="aléatoire"
                />
                <button
                  type="button"
                  className="btn btn-chip"
                  title="Seed aléatoire"
                  onClick={() => setSeedText(String(Math.floor(Math.random() * 2 ** 32)))}
                >
                  Aléa
                </button>
              </div>
            </label>
            <label className="field">
              <span>Quantification</span>
              <select
                value={quantize === null ? "" : String(quantize)}
                onChange={(e) => setQuantize(e.target.value === "" ? null : Number(e.target.value))}
              >
                <option value="">Aucune</option>
                {(caps?.quantize_options ?? []).map((q) => (
                  <option key={q} value={q}>
                    {q} bit
                  </option>
                ))}
              </select>
            </label>
          </div>

          <div className="field-row">
            {!isEdit && (
              <label className="field">
                <span>Lot ({caps?.batch_limits.min ?? 1}–{caps?.batch_limits.max ?? 4})</span>
                <input
                  type="number"
                  min={caps?.batch_limits.min ?? 1}
                  max={caps?.batch_limits.max ?? 4}
                  value={batch}
                  onChange={(e) => setBatch(Number(e.target.value))}
                />
              </label>
            )}
            <label className="field">
              <span>Planche (board)</span>
              <input
                type="text"
                value={board}
                onChange={(e) => setBoard(e.target.value)}
                placeholder="ex : portraits"
              />
            </label>
          </div>

          <div className="field">
            <span>LoRAs</span>
            {loras.map((lora, i) => (
              <div className="inline lora-row" key={i}>
                <input
                  type="text"
                  placeholder="Chemin du LoRA"
                  value={lora.path}
                  onChange={(e) =>
                    setLoras((prev) =>
                      prev.map((x, j) => (j === i ? { ...x, path: e.target.value } : x)),
                    )
                  }
                />
                <input
                  type="number"
                  min={0}
                  max={2}
                  step={0.05}
                  value={lora.strength}
                  onChange={(e) =>
                    setLoras((prev) =>
                      prev.map((x, j) => (j === i ? { ...x, strength: Number(e.target.value) } : x)),
                    )
                  }
                  style={{ width: 80 }}
                />
                <button
                  type="button"
                  className="btn btn-chip"
                  onClick={() => setLoras((prev) => prev.filter((_, j) => j !== i))}
                  aria-label="Retirer"
                >
                  ✕
                </button>
              </div>
            ))}
            <button
              type="button"
              className="btn btn-chip"
              onClick={() => setLoras((prev) => [...prev, { path: "", strength: 1 }])}
            >
              + Ajouter un LoRA
            </button>
          </div>

          {isEdit ? (
            <div className="field">
              <span>Images d'entrée ({editImages.length}/{maxEditImages})</span>
              {editImages.length === 0 && (
                <p className="muted hint">Ajoutez de 1 à {maxEditImages} images à éditer.</p>
              )}
              {editImages.map((img, i) => (
                <div className="inline edit-image-row" key={`${img.filename}-${i}`}>
                  <img
                    className="edit-thumb"
                    src={`data:image/jpeg;base64,${img.base64}`}
                    alt={`Image ${i + 1}`}
                    width={72}
                  />
                  <span className="muted mono">#{i + 1}</span>
                  <button
                    type="button"
                    className="btn btn-chip"
                    disabled={i === 0}
                    onClick={() => moveEditImage(i, -1)}
                    aria-label="Déplacer à gauche"
                  >
                    ←
                  </button>
                  <button
                    type="button"
                    className="btn btn-chip"
                    disabled={i === editImages.length - 1}
                    onClick={() => moveEditImage(i, 1)}
                    aria-label="Déplacer à droite"
                  >
                    →
                  </button>
                  <button
                    type="button"
                    className="btn btn-chip"
                    onClick={() => setEditImages((prev) => prev.filter((_, j) => j !== i))}
                    aria-label="Retirer"
                  >
                    ✕
                  </button>
                </div>
              ))}
              <input
                ref={editFileInputRef}
                type="file"
                accept="image/png,image/jpeg,image/webp"
                multiple
                style={{ display: "none" }}
                onChange={(e) => {
                  void onPickEditImages(e.target.files);
                  e.target.value = "";
                }}
              />
              <button
                type="button"
                className="btn btn-chip"
                disabled={editImages.length >= maxEditImages}
                onClick={() => editFileInputRef.current?.click()}
              >
                + Ajouter une image
              </button>
            </div>
          ) : (
            <div className="field">
              <span>Image d'entrée (img2img)</span>
              <input
                type="file"
                accept="image/png,image/jpeg,image/webp"
                onChange={(e) => void onPickImage(e.target.files?.[0])}
              />
              {imageBase64 && (
                <div className="img2img-preview">
                  <img
                    src={`data:image/jpeg;base64,${imageBase64.base64}`}
                    alt="Aperçu"
                    width={96}
                  />
                  <label className="field">
                    <span>Force d'image : {imageStrength.toFixed(2)}</span>
                    <input
                      type="range"
                      min={0.1}
                      max={0.95}
                      step={0.05}
                      value={imageStrength}
                      onChange={(e) => setImageStrength(Number(e.target.value))}
                    />
                  </label>
                  <button
                    type="button"
                    className="btn btn-chip"
                    onClick={() => {
                      setImageBase64(null);
                      setImagePath(null);
                    }}
                  >
                    Retirer
                  </button>
                </div>
              )}
            </div>
          )}

          <p className="muted estimate">
            Estimation : {steps} pas · {width}×{height} ({mp} Mpx)
            {estSeconds !== null ? ` · ≈ ${estSeconds}s / image` : ""}
          </p>

          <button
            className="btn btn-primary btn-lg"
            type="submit"
            disabled={submitting || !prompt.trim() || (isEdit && editImages.length === 0)}
          >
            {submitting ? "Envoi…" : isEdit ? "Éditer" : "Générer"}
          </button>
        </form>

        <aside className="card glass live-card">
          <h2 className="bench-section-title">Tirage — épreuve en direct</h2>
          {!live && !resultSrc && (
            <div className="live-preview">
              <div className="live-frame live-frame-idle">
                <div className="live-frame-inner" />
              </div>
            </div>
          )}
          {live && (
            <>
              <div className="live-head">
                <span className="exposure-id">Nº {live.id.slice(0, 8)}</span>
                <span className="live-metrics tnum">
                  POSE {live.step}/{live.totalSteps || "—"} · {elapsed}s
                </span>
              </div>
              <ProgressBar
                value={live.totalSteps > 0 ? (live.step / live.totalSteps) * 100 : 0}
                indeterminate={live.totalSteps === 0}
                glow
                showPercent
              />
              {live.statusLine && <p className="status-line mono">{live.statusLine}</p>}
              <div className="live-preview">
                <div className={`live-frame ${live.previewSrc ? "live-frame-active" : ""}`}>
                  <Particles />
                  <span className="glow-ring" aria-hidden />
                  <div className="live-frame-inner">
                    {live.previewPrev && live.previewSrc && (
                      <img
                        src={live.previewPrev}
                        alt=""
                        aria-hidden
                        className="preview-frame preview-frame-under"
                      />
                    )}
                    {live.previewSrc && (
                      <img
                        key={live.previewSrc}
                        src={live.previewSrc}
                        alt="Aperçu en cours"
                        className="preview-frame"
                      />
                    )}
                    {live.previewSrc && <span className="scanline" aria-hidden />}
                  </div>
                </div>
              </div>
              <button className="btn btn-danger" type="button" onClick={() => void cancelLive()}>
                Annuler
              </button>
            </>
          )}
          {resultSrc && !live && (
            <div className="live-result">
              <p className="micro-label">Épreuve — tirage final</p>
              <div className="reveal-frame">
                <span className="reveal-ring" aria-hidden />
                <a href={resultSrc} target="_blank" rel="noreferrer">
                  <img src={resultSrc} alt="Résultat" className="reveal-img" />
                </a>
              </div>
            </div>
          )}
        </aside>
      </div>
    </div>
  );
}

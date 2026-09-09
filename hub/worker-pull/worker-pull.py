#!/usr/bin/env python3
"""MLXBits Image Studio — agent pull pour Mac mini (mode "cerveau").

Récupère les jobs de génération depuis le hub Proxmox (polling HTTP),
les exécute avec mflux en local, et renvoie progression, previews et
image finale. Aucun port entrant nécessaire sur la mini : seul le hub
doit être joignable (LAN ou NetBird).

Lancé via launchd (com.gildas.worker-pull, KeepAlive).
Python : utiliser l'env mflux (Pillow inclus) :
    ~/mflux-env/bin/python ~/mflux-api/worker-pull.py
"""
import base64
import io
import json
import os
import random
import re
import shutil
import subprocess
import tempfile
import time
import urllib.request
import urllib.error
from pathlib import Path

BASE = Path.home() / "mflux-api"
HUB_URL = os.environ.get("HUB_URL", "http://10.10.0.13:8000").rstrip("/")
WORKER_TOKEN = os.environ.get("WORKER_TOKEN", "klein-4b")
MFLUX_BIN = os.environ.get("MFLUX_BIN", str(Path.home() / "mflux-env/bin"))
MODEL_REPO = os.environ.get("MODEL_REPO", "ar9av/FLUX.2-klein-4B-mflux-4bit")
BASE_MODEL = os.environ.get("BASE_MODEL", "flux2-klein-4b")

# Modèles sélectionnables dans l'UI : id -> repo, binaire CLI, base, steps.
MODEL_REGISTRY = {
    "flux2-klein-4b": {
        "repo": "ar9av/FLUX.2-klein-4B-mflux-4bit",
        "binary": "mflux-generate-flux2",
        "base_model": "flux2-klein-4b",
        "default_steps": 4,
    },
    "z-image-turbo": {
        "repo": "filipstrand/Z-Image-Turbo-mflux-4bit",
        "binary": "mflux-generate-z-image-turbo",
        "base_model": "z-image-turbo",
        "default_steps": 8,
    },
    "flux2-klein-4b-uncensored-q4": {
        "repo": "/Users/gildas/mflux-models/out/klein-4b-uncensored-q4",
        "binary": "mflux-generate-flux2",
        "base_model": "flux2-klein-4b",
        "default_steps": 4,
    },
    "flux2-klein-4b-uncensored-q8": {
        "repo": "/Users/gildas/mflux-models/out/klein-4b-uncensored-q8",
        "binary": "mflux-generate-flux2",
        "base_model": "flux2-klein-4b",
        "default_steps": 4,
    },
}
POLL_INTERVAL = float(os.environ.get("POLL_INTERVAL", "2"))
STEPWISE_ROOT = BASE / "stepwise"
STEP_RE = re.compile(r"(\d+)/(\d+)")
LLM_MODEL = os.environ.get("LLM_MODEL", "mlx-community/Qwen3.5-4B-MLX-4bit")
_llm = {}


def enhance_prompt_text(raw):
    """Réécrit un prompt court en prompt riche via le petit LLM local."""
    if "model" not in _llm:
        from mlx_lm import load
        log(f"chargement LLM {LLM_MODEL}…")
        _llm["model"], _llm["tok"] = load(LLM_MODEL)
    model, tok = _llm["model"], _llm["tok"]
    from mlx_lm import generate
    msgs = [
        {"role": "system", "content": (
            "Expand short ideas into rich, detailed image-generation prompts. "
            "Reply with ONLY the expanded prompt, no explanations.")},
        {"role": "user", "content": raw},
    ]
    prompt = tok.apply_chat_template(msgs, tokenize=False,
                                     add_generation_prompt=True,
                                     enable_thinking=False)
    out = generate(model, tok, prompt=prompt, max_tokens=150, verbose=False)
    return out.strip().strip("\"")


def hub(method, path, payload=None, timeout=15):
    """Appel JSON authentifié vers le hub. Lève en cas d'échec."""
    req = urllib.request.Request(
        HUB_URL + path,
        data=json.dumps(payload or {}).encode() if method != "GET" or payload else None,
        headers={"Authorization": "Bearer " + WORKER_TOKEN,
                 "Content-Type": "application/json"},
        method=method,
    )
    if method == "GET" and not payload:
        req.data = None
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as exc:
        try:
            detail = exc.read().decode()[:200]
        except Exception:
            detail = ""
        raise RuntimeError(f"hub {exc.code}: {detail}")


def hub_get(path, timeout=15):
    req = urllib.request.Request(
        HUB_URL + path,
        headers={"Authorization": "Bearer " + WORKER_TOKEN},
        method="GET",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def log(*args):
    print(time.strftime("[%F %T]"), *args, flush=True)


def downscale_jpeg(path, max_edge=512, quality=60):
    try:
        from PIL import Image
        img = Image.open(path)
        img.thumbnail((max_edge, max_edge))
        buf = io.BytesIO()
        img.convert("RGB").save(buf, "JPEG", quality=quality)
        return base64.b64encode(buf.getvalue()).decode()
    except Exception as exc:
        log("preview ignorée:", exc)
        return None


def resolve_input(value):
    """hub://<id> → télécharge depuis le hub, sinon chemin local tel quel."""
    if isinstance(value, str) and value.startswith("hub://"):
        upload_id = value[len("hub://"):]
        data = hub_get(f"/api/v1/worker/files/{upload_id}", timeout=120)
        suffix = ".png"
        dest = Path(tempfile.gettempdir()) / f"hub_input_{upload_id}{suffix}"
        dest.write_bytes(data)
        return str(dest)
    return value


def run_job(job):
    job_id, params = job["id"], job["params"]
    spec = MODEL_REGISTRY.get(params.get("model") or "flux2-klein-4b",
                              MODEL_REGISTRY["flux2-klein-4b"])
    binary_name = spec["binary"]
    if params.get("edit_mode"):
        if spec["binary"] != "mflux-generate-flux2":
            raise RuntimeError("édition supportée uniquement sur FLUX.2")
        binary_name = "mflux-generate-flux2-edit"
    edit = bool(params.get("edit_mode"))
    fast_mode = bool(params.get("fast_mode")) and not edit
    upscale_factor = int(params.get("upscale_factor") or 4)

    enhanced = None
    if params.get("enhance_prompt") and params.get("prompt"):
        post_phase(job_id, "Amélioration du prompt (Qwen3.5)…")
        try:
            enhanced = enhance_prompt_text(params["prompt"])
            params = dict(params, prompt=enhanced)
            log(f"job {job_id}: prompt amélioré ({len(enhanced)} car.)")
        except Exception as exc:
            log(f"job {job_id}: enhance échoué ({exc}), prompt d'origine")

    if fast_mode:
        # Basse résolution : long bord plafonné à 384 (rapide), puis upscale.
        w, h = int(params.get("width") or 512), int(params.get("height") or 512)
        longest = max(w, h)
        if longest > 384:
            scale_down = 384.0 / longest
            w, h = max(64, int(w * scale_down) // 8 * 8), max(64, int(h * scale_down) // 8 * 8)
        params = dict(params, width=w, height=h)
        log(f"job {job_id}: mode rapide {w}x{h} puis x{upscale_factor}")
    seed = params.get("seed")
    if seed is None:
        seed = random.randint(0, 2**31 - 1)

    stepwise = STEPWISE_ROOT / job_id
    stepwise.mkdir(parents=True, exist_ok=True)
    out_file = stepwise / "output.png"

    default_steps = params.get("steps") or spec["default_steps"]
    args = [
        os.path.join(MFLUX_BIN, binary_name),
        "--model", params.get("model_repo") or spec["repo"],
        "--base-model", spec["base_model"],
        "--prompt", params.get("prompt", ""),
        "--steps", str(default_steps),
        "--guidance", str(params.get("guidance") or 1.0),
        "--seed", str(seed),
        "--output", str(out_file),
        "--stepwise-image-output-dir", str(stepwise),
        "--metadata",
    ]
    if not edit:
        # Hors édition : dimensions explicites. En édition : taille source
        # native (défaut du CLI) pour préserver les détails.
        args += ["--width", str(params.get("width") or 512),
                 "--height", str(params.get("height") or 512)]
    if not edit and params.get("negative_prompt"):
        args += ["--negative-prompt", params["negative_prompt"]]
    if edit:
        paths = [resolve_input(p) for p in (params.get("edit_image_paths") or [])]
        if not paths:
            raise RuntimeError("edit_image_paths vide")
        args += ["--image-paths"] + paths[:4]

    log(f"job {job_id}: {binary_name} steps={default_steps} seed={seed}")
    proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, bufsize=1)
    last_preview, last_sent_step = "", 0
    last_cancel_check = 0.0
    try:
        for line in proc.stdout:
            m = STEP_RE.search(line)
            if m:
                step, total = int(m.group(1)), int(m.group(2))
                if total and 0 < step <= total and step != last_sent_step:
                    last_sent_step = step
                    post_progress(job_id, step, total, stepwise, last_preview,
                                  width=params.get("width"), height=params.get("height"))
                    last_preview = preview_state[0]
            now = time.time()
            if now - last_cancel_check > 2:
                last_cancel_check = now
                if check_cancelled(job_id):
                    log(f"job {job_id}: annulation demandée")
                    proc.terminate()
                    hub("POST", f"/api/v1/worker/jobs/{job_id}/fail",
                        {"error": "__cancelled__"})
                    return
        code = proc.wait()
    finally:
        pass

    if code == 0 and out_file.exists():
        final_path = out_file
        if fast_mode:
            post_phase(job_id, f"Upscale x{upscale_factor} (Real-ESRGAN)…")
            upscaled = stepwise / "upscaled.png"
            proc2 = subprocess.run(
                [os.path.expanduser("~/realesrgan-env/bin/python"),
                 str(Path(__file__).parent / "upscale.py"),
                 str(out_file), str(upscaled), str(upscale_factor)],
                capture_output=True, text=True, timeout=1200,
            )
            if proc2.returncode == 0 and upscaled.exists():
                final_path = upscaled
                log(f"job {job_id}: upscale OK")
            else:
                log(f"job {job_id}: upscale échoué, image d'origine ({proc2.stderr[-200:]})")
        with open(final_path, "rb") as f:
            image_b64 = base64.b64encode(f.read()).decode()
        payload = {"image_b64": image_b64, "seed": seed}
        if enhanced:
            payload["enhanced_prompt"] = enhanced
        hub("POST", f"/api/v1/worker/jobs/{job_id}/complete",
            payload, timeout=180)
        log(f"job {job_id}: terminé ({len(image_b64) // 1024} Ko envoyés)")
    else:
        hub("POST", f"/api/v1/worker/jobs/{job_id}/fail",
            {"error": f"mflux exit {code}"})
        log(f"job {job_id}: échec (exit {code})")
    shutil.rmtree(stepwise, ignore_errors=True)


preview_state = [""]


def post_phase(job_id, phase):
    try:
        hub("POST", f"/api/v1/worker/jobs/{job_id}/progress",
            {"step": 0, "total": 0, "phase": phase})
    except Exception as exc:
        log(f"phase ignorée: {exc}")


def post_progress(job_id, step, total, stepwise_dir, last_preview,
                    width=None, height=None):
    preview_b64 = None
    try:
        frames = sorted(stepwise_dir.glob("*.png"), key=lambda p: p.stat().st_mtime)
        if frames and frames[-1].name != last_preview:
            preview_state[0] = frames[-1].name
            preview_b64 = downscale_jpeg(frames[-1])
    except Exception:
        pass
    payload = {"step": step, "total": total}
    if width and height:
        payload["width"], payload["height"] = width, height
    if preview_b64:
        payload["preview_b64"] = preview_b64
    hub("POST", f"/api/v1/worker/jobs/{job_id}/progress", payload)


def check_cancelled(job_id):
    try:
        st = hub("GET", f"/api/v1/worker/jobs/{job_id}/status", timeout=10)
        return bool(st.get("cancel_requested")) or st.get("status") in ("cancelled",)
    except Exception:
        return False


def main():
    BASE.mkdir(parents=True, exist_ok=True)
    STEPWISE_ROOT.mkdir(parents=True, exist_ok=True)
    log(f"agent pull → hub {HUB_URL} (poll {POLL_INTERVAL}s)")
    failures = 0
    while True:
        try:
            hub("POST", "/api/v1/worker/heartbeat",
                {"model": MODEL_REPO, "mflux": "0.19.1", "model_memory_gb": 4.8})
            nxt = hub("GET", "/api/v1/worker/jobs/next", timeout=20)
            failures = 0
            job = (nxt or {}).get("job")
            if job:
                try:
                    run_job(job)
                except Exception as exc:
                    log(f"job {job['id']}: erreur {exc}")
                    try:
                        hub("POST", f"/api/v1/worker/jobs/{job['id']}/fail",
                            {"error": str(exc)})
                    except Exception:
                        pass
            else:
                time.sleep(POLL_INTERVAL)
        except Exception as exc:
            failures += 1
            wait = min(POLL_INTERVAL * (2 ** min(failures, 5)), 60)
            log(f"hub injoignable ({exc}) — nouvel essai dans {wait:.0f}s")
            time.sleep(wait)


if __name__ == "__main__":
    main()

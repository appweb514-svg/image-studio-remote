"""MLXBits Image Studio — hub Proxmox.

Sert le frontend statique, gère l'authentification (login utilisateur/mot de
passe), stocke les images et leurs métadonnées (SQLite + volume).

Architecture "pull" : le hub possède la file de jobs, et le worker mflux sur
la Mac mini vient les chercher (polling). Aucun accès réseau entrant vers la
mini n'est nécessaire — NetBird devient optionnel, les coupures sont
absorbées par le polling.

Le navigateur ne parle qu'au hub. La mini n'est jamais exposée.
"""
import base64
import json
import os
import queue
import secrets
import sqlite3
import threading
import time
import uuid
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles

DATA = Path(os.environ.get("STUDIO_DATA", "/data"))
IMAGES_DIR = DATA / "images"
UPLOADS_DIR = DATA / "uploads"
PREVIEWS_DIR = DATA / "previews"
DB_PATH = DATA / "studio.db"
WORKER_TOKEN = os.environ.get("WORKER_TOKEN", "klein-4b")
ADMIN_USER = os.environ.get("ADMIN_USER", "admin")
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "studio")
COOKIE = "studio_session"
SESSION_TTL = 30 * 24 * 3600  # 30 jours
HEARTBEAT_TTL = 60  # worker considéré en ligne si heartbeat < 60 s

for d in (DATA, IMAGES_DIR, UPLOADS_DIR, PREVIEWS_DIR):
    d.mkdir(parents=True, exist_ok=True)

app = FastAPI(title="MLXBits Image Studio hub")


@app.middleware("http")
async def no_store_api(request: Request, call_next):
    """Pas de cache navigateur sur l'API (capabilities, queue, jobs…) :
    l'UI doit toujours voir l'état frais, sinon les nouveaux modèles
    ou jobs n'apparaissent qu'après expiration du cache heuristique."""
    response = await call_next(request)
    if request.url.path.startswith("/api/"):
        response.headers["Cache-Control"] = "no-store, must-revalidate"
    return response


# ------------------------------------------------------------------ storage

def db():
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    with db() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS images (
                id TEXT PRIMARY KEY,
                filename TEXT NOT NULL,
                path TEXT NOT NULL,
                board TEXT DEFAULT 'Default',
                source TEXT DEFAULT 'generation',
                prompt TEXT, negative_prompt TEXT, model TEXT,
                seed INTEGER, width INTEGER, height INTEGER,
                steps INTEGER, guidance REAL,
                flag TEXT, rating INTEGER DEFAULT 0,
                meta_json TEXT,
                created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS sessions (
                token TEXT PRIMARY KEY,
                created_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS worker_jobs (
                id TEXT PRIMARY KEY,
                kind TEXT DEFAULT 'generate',
                params_json TEXT NOT NULL,
                status TEXT DEFAULT 'queued',
                cancel_requested INTEGER DEFAULT 0,
                progress_json TEXT DEFAULT '{}',
                preview_path TEXT,
                output_image_id TEXT,
                error TEXT,
                created_at TEXT NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS uploads (
                id TEXT PRIMARY KEY,
                filename TEXT,
                path TEXT NOT NULL,
                mime TEXT,
                created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS worker_state (
                key TEXT PRIMARY KEY,
                value TEXT,
                updated_at REAL NOT NULL
            );
            """
        )


init_db()

# ------------------------------------------------------------ event bus SSE

EVENT_QUEUES: list = []
EVENT_LOCK = threading.Lock()


def emit_local(event: str, payload: dict):
    frame = f"event: {event}\ndata: {json.dumps(payload)}\r\n\r\n"
    with EVENT_LOCK:
        for q in list(EVENT_QUEUES):
            q.put(frame)


# --------------------------------------------------------------------- auth

def check_session(request: Request) -> bool:
    token = request.cookies.get(COOKIE, "")
    if not token:
        return False
    with db() as conn:
        row = conn.execute("SELECT created_at FROM sessions WHERE token=?", (token,)).fetchone()
    return bool(row and time.time() - row["created_at"] < SESSION_TTL)


def require_auth(request: Request):
    if not check_session(request):
        raise HTTPException(401, "unauthorized")


def require_worker(request: Request):
    auth = request.headers.get("Authorization", "")
    token = request.query_params.get("worker_token", "")
    if auth != "Bearer " + WORKER_TOKEN and token != WORKER_TOKEN:
        raise HTTPException(401, "unauthorized")


@app.post("/api/v1/auth/login")
def login(body: dict):
    if body.get("username") != ADMIN_USER or body.get("password") != ADMIN_PASSWORD:
        raise HTTPException(401, "identifiants invalides")
    token = secrets.token_urlsafe(32)
    with db() as conn:
        conn.execute("INSERT INTO sessions VALUES (?, ?)", (token, time.time()))
        conn.execute("DELETE FROM sessions WHERE created_at < ?", (time.time() - SESSION_TTL,))
    resp = JSONResponse({"ok": True, "username": ADMIN_USER})
    resp.set_cookie(COOKIE, token, max_age=SESSION_TTL, httponly=True, samesite="lax")
    return resp


@app.post("/api/v1/auth/logout")
def logout():
    resp = JSONResponse({"ok": True})
    resp.delete_cookie(COOKIE)
    return resp


@app.get("/api/v1/auth/me")
def me(request: Request):
    require_auth(request)
    return {"username": ADMIN_USER}


# ------------------------------------------------------------- static data

STATIC_CAPABILITIES = {
    "families": [{"id": "flux", "display_name": "FLUX.2", "web_enqueue": True,
                  "supports_edit": True, "max_edit_images": 4,
                  "supports_fast_mode": True, "supports_prompt_enhance": True,
                  "fast_mode_note": "Génération 384px + upscale Superscale x4 (Neural Engine)",
                  "prompt_enhance_note": "Réécriture du prompt par Qwen3.5-4B local"},
                 {"id": "zimage", "display_name": "Z-Image", "web_enqueue": True,
                  "supports_edit": False, "max_edit_images": 0,
                  "supports_fast_mode": True, "supports_prompt_enhance": True,
                  "fast_mode_note": "Génération 384px + upscale Superscale x4 (Neural Engine)",
                  "prompt_enhance_note": "Réécriture du prompt par Qwen3.5-4B local"}],
    "models": [
        {"id": "flux2-klein-4b", "family": "flux", "display_name": "FLUX.2 Klein 4B",
         "is_distilled": True, "default_steps": 4, "default_guidance": 1.0,
         "supports_negative_prompt": False, "recommended_quantize": 8,
         "approximate_size_gb": 4.6},
        {"id": "flux2-klein-9b", "family": "flux", "display_name": "FLUX.2 Klein 9B",
         "is_distilled": True, "default_steps": 4, "default_guidance": 1.0,
         "supports_negative_prompt": False, "recommended_quantize": 8,
         "approximate_size_gb": 9.8},
        {"id": "z-image-turbo", "family": "zimage", "display_name": "Z-Image Turbo 4-bit",
         "is_distilled": True, "default_steps": 8, "default_guidance": 1.0,
         "supports_negative_prompt": True, "recommended_quantize": 4,
         "approximate_size_gb": 5.5},
        {"id": "flux2-klein-4b-uncensored-q4", "family": "flux",
         "display_name": "FLUX.2 Klein 4B uncensored (Q4)",
         "is_distilled": True, "default_steps": 4, "default_guidance": 1.0,
         "supports_negative_prompt": False, "recommended_quantize": 4,
         "approximate_size_gb": 4.3},
        {"id": "flux2-klein-4b-uncensored-q8", "family": "flux",
         "display_name": "FLUX.2 Klein 4B uncensored (Q8)",
         "is_distilled": True, "default_steps": 4, "default_guidance": 1.0,
         "supports_negative_prompt": False, "recommended_quantize": 8,
         "approximate_size_gb": 8.0},
    ],
    "quantize_options": [0, 3, 4, 6, 8],
    "batch_limits": {"min": 1, "max": 4},
    "dimension_constraints": {"min_edge": 64, "max_edge": 2048, "multiple_of": 8},
    "timing_estimate_available": False,
}

STATIC_MODELS = [
    {"id": "flux2-klein-4b", "display_name": "FLUX.2 Klein 4B", "family": "flux",
     "on_disk_q8": True, "on_disk_q4": True, "size_gb_q8": 8.2, "size_gb_q4": 4.6,
     "repo_url": "https://huggingface.co/black-forest-labs/FLUX.2-klein-4B"},
    {"id": "flux2-klein-9b", "display_name": "FLUX.2 Klein 9B", "family": "flux",
     "on_disk_q8": False, "on_disk_q4": True, "size_gb_q8": 17.6, "size_gb_q4": 9.8,
     "repo_url": "https://huggingface.co/black-forest-labs/FLUX.2-klein-9B"},
]

UPSCALE_MODELS = [
    {"name": "realesrgan-x4plus", "display_name": "General photo (4×)", "scale": 4,
     "tile_size": 512, "is_default": True, "installed": False, "downloading": False,
     "supports_face_enhance": False,
     "short_description": "Photos générales ×4",
     "detailed_description": "Modèle par défaut (à installer sur le worker)."},
    {"name": "realesrgan-x2plus", "display_name": "General photo (2×)", "scale": 2,
     "tile_size": 512, "is_default": False, "installed": False, "downloading": False,
     "supports_face_enhance": False,
     "short_description": "Photos générales ×2",
     "detailed_description": "Upscale léger, fidèle à la source."},
]


def worker_online() -> bool:
    with db() as conn:
        row = conn.execute("SELECT updated_at FROM worker_state WHERE key='heartbeat'").fetchone()
    return bool(row and time.time() - row["updated_at"] < HEARTBEAT_TTL)


def worker_info() -> dict:
    with db() as conn:
        row = conn.execute("SELECT value FROM worker_state WHERE key='info'").fetchone()
    try:
        return json.loads(row["value"]) if row else {}
    except Exception:
        return {}


def hub_system() -> dict:
    import platform
    import shutil
    total_mem_gb = 0.0
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    total_mem_gb = round(int(line.split()[1]) / 1048576.0, 1)
                    break
    except OSError:
        pass
    disk = shutil.disk_usage(DATA)
    return {
        "chip": f"Proxmox ({platform.machine()})",
        "chip_generation": platform.machine(),
        "memory": {"total_gb": total_mem_gb},
        "storage": {"free_gb": round(disk.free / 1073741824.0, 1),
                    "total_gb": round(disk.total / 1073741824.0, 1)},
    }


# ------------------------------------------------------------------ status

@app.get("/api/v1/status")
def status():
    online = worker_online()
    info = worker_info()
    with db() as conn:
        pending = conn.execute(
            "SELECT COUNT(*) c FROM worker_jobs WHERE status IN ('queued','running')").fetchone()["c"]
        running = conn.execute(
            "SELECT COUNT(*) c FROM worker_jobs WHERE status='running'").fetchone()["c"]
    system = hub_system()
    system["loaded_model"] = info.get("model")
    system["loaded_model_memory_gb"] = info.get("model_memory_gb")
    system["queue_length"] = pending
    versions = {"app": "hub-2.0"}
    if info.get("mflux"):
        versions["mflux"] = info["mflux"]
    system["versions"] = versions
    return {
        "app": "MLXBits Image Studio",
        "worker_online": online,
        "remoteAccess": {"is_running": True, "allow_lan": True,
                         "require_auth": True, "connected_clients": len(EVENT_QUEUES)},
        "system": system,
        "queue": {"pending": pending, "running_flux": running > 0,
                  "running_krea2": False, "running_zimage": False},
    }


@app.get("/api/v1/capabilities")
def capabilities():
    return JSONResponse(STATIC_CAPABILITIES)


@app.get("/api/v1/models")
def models():
    return JSONResponse(STATIC_MODELS)


@app.get("/api/v1/presets")
def presets(request: Request):
    require_auth(request)
    return JSONResponse({"templates": [], "model_defaults": []})


# -------------------------------------------------------------------- jobs

def job_row(row) -> dict:
    params = json.loads(row["params_json"] or "{}")
    progress = json.loads(row["progress_json"] or "{}")
    status = row["status"]
    ui_status = {"queued": "pending", "running": "running", "completed": "completed",
                 "failed": "failed", "cancelled": "cancelled"}.get(status, status)
    total = int(progress.get("total") or params.get("steps") or 4)
    step = int(progress.get("step") or 0)
    return {
        "id": row["id"], "family": "flux", "status": ui_status,
        "prompt": params.get("prompt"), "model": params.get("model") or "flux2-klein-4b",
        "width": params.get("width", 512), "height": params.get("height", 512),
        "steps": params.get("steps", 4), "guidance": params.get("guidance", 1.0),
        "seed": params.get("seed"), "resolved_seed": params.get("seed"),
        "current_step": step, "total_steps": total,
        "progress": step / max(total, 1),
        "has_image_input": bool(params.get("edit_mode")),
        "output_path": f"/api/v1/images/{row['output_image_id']}" if row["output_image_id"] else None,
        "output_paths": [f"/api/v1/images/{row['output_image_id']}"] if row["output_image_id"] else [],
        "board": params.get("board", "Default"),
        "created_at": row["created_at"],
        "preview_url": f"/api/v1/jobs/{row['id']}/preview",
        "error": row["error"],
    }


@app.post("/api/v1/generate")
def generate(request: Request, body: dict):
    require_auth(request)
    prompt = (body.get("prompt") or "").strip()
    if not prompt:
        raise HTTPException(400, "prompt requis")
    job_id = uuid.uuid4().hex[:12]
    with db() as conn:
        conn.execute(
            """INSERT INTO worker_jobs
               (id, kind, params_json, status, created_at, updated_at)
               VALUES (?,?,?,?,?,?)""",
            (job_id, "generate", json.dumps(body), "queued",
             time.strftime("%Y-%m-%dT%H:%M:%S"), time.time()),
        )
    emit_local("jobCreated", {"job_id": job_id, "family": "flux"})
    emit_local("queueChanged", {})
    return {"ok": True, "job_id": job_id}


@app.get("/api/v1/queue")
def queue(request: Request):
    require_auth(request)
    with db() as conn:
        rows = conn.execute(
            "SELECT * FROM worker_jobs ORDER BY created_at DESC LIMIT 100").fetchall()
    return [job_row(r) for r in rows]


@app.get("/api/v1/jobs/{job_id}")
def get_job(job_id: str, request: Request):
    require_auth(request)
    with db() as conn:
        row = conn.execute("SELECT * FROM worker_jobs WHERE id=?", (job_id,)).fetchone()
    if not row:
        raise HTTPException(404, "not found")
    return job_row(row)


@app.get("/api/v1/jobs/{job_id}/preview")
def job_preview(job_id: str, request: Request):
    require_auth(request)
    with db() as conn:
        row = conn.execute("SELECT * FROM worker_jobs WHERE id=?", (job_id,)).fetchone()
    if not row:
        raise HTTPException(404, "not found")
    if row["output_image_id"]:
        with db() as conn:
            img = conn.execute("SELECT path FROM images WHERE id=?",
                               (row["output_image_id"],)).fetchone()
        if img and Path(img["path"]).exists():
            return FileResponse(img["path"], media_type="image/png")
    preview = PREVIEWS_DIR / f"{job_id}.jpg"
    if preview.exists():
        return FileResponse(preview, media_type="image/jpeg")
    raise HTTPException(404, "preview pas encore disponible")


@app.post("/api/v1/jobs/{job_id}/cancel")
def cancel_job(job_id: str, request: Request):
    require_auth(request)
    with db() as conn:
        row = conn.execute("SELECT status FROM worker_jobs WHERE id=?", (job_id,)).fetchone()
        if not row:
            raise HTTPException(404, "not found")
        if row["status"] == "queued":
            conn.execute("UPDATE worker_jobs SET status='cancelled', updated_at=? WHERE id=?",
                         (time.time(), job_id))
            emit_local("jobCancelled", {"job_id": job_id})
        elif row["status"] == "running":
            conn.execute("UPDATE worker_jobs SET cancel_requested=1, updated_at=? WHERE id=?",
                         (time.time(), job_id))
        emit_local("queueChanged", {})
    return {"ok": True}


@app.post("/api/v1/jobs/{job_id}/retry")
@app.post("/api/v1/jobs/{job_id}/duplicate")
def retry_job(job_id: str, request: Request):
    require_auth(request)
    with db() as conn:
        row = conn.execute("SELECT params_json FROM worker_jobs WHERE id=?", (job_id,)).fetchone()
        if not row:
            raise HTTPException(404, "not found")
        new_id = uuid.uuid4().hex[:12]
        conn.execute(
            """INSERT INTO worker_jobs
               (id, kind, params_json, status, created_at, updated_at)
               VALUES (?,?,?,?,?,?)""",
            (new_id, "generate", row["params_json"], "queued",
             time.strftime("%Y-%m-%dT%H:%M:%S"), time.time()),
        )
    emit_local("jobCreated", {"job_id": new_id, "family": "flux"})
    emit_local("queueChanged", {})
    return {"ok": True, "job_id": new_id}


@app.delete("/api/v1/jobs/{job_id}")
def delete_job(job_id: str, request: Request):
    require_auth(request)
    with db() as conn:
        row = conn.execute("SELECT status FROM worker_jobs WHERE id=?", (job_id,)).fetchone()
        if not row:
            raise HTTPException(404, "not found")
        if row["status"] == "running":
            raise HTTPException(409, "job en cours — annulez-le d'abord")
        conn.execute("DELETE FROM worker_jobs WHERE id=?", (job_id,))
    emit_local("queueChanged", {})
    return {"ok": True}


@app.patch("/api/v1/queue/reorder")
def reorder(request: Request, body: dict):
    require_auth(request)
    order = [i for i in (body.get("order") or []) if isinstance(i, str)]
    base = time.time()
    with db() as conn:
        for index, job_id in enumerate(order):
            row = conn.execute(
                "SELECT status FROM worker_jobs WHERE id=?", (job_id,)).fetchone()
            if row and row["status"] in ("queued",):
                conn.execute(
                    "UPDATE worker_jobs SET created_at=?, updated_at=? WHERE id=?",
                    (time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(base + index)),
                     time.time(), job_id),
                )
    emit_local("queueChanged", {})
    return {"ok": True}


# ------------------------------------------------------------------ uploads

@app.post("/api/v1/uploads")
def uploads(request: Request, body: dict):
    require_auth(request)
    raw = body.get("data_base64", "")
    mime = (body.get("mime") or "").lower()
    ext = {"image/png": "png", "image/jpeg": "jpg", "image/webp": "webp"}.get(mime)
    if not ext:
        raise HTTPException(415, "mime non supporté")
    try:
        data = base64.b64decode(raw)
    except Exception:
        raise HTTPException(400, "base64 invalide")
    if len(data) > 20 * 1024 * 1024:
        raise HTTPException(413, "trop volumineux (max 20 Mo)")
    # Vérification magic bytes (png/jpeg/webp).
    heads = {"png": b"\x89PNG", "jpg": b"\xff\xd8\xff", "webp": b"RIFF"}
    if not data.startswith(heads[ext]) or (ext == "webp" and data[8:12] != b"WEBP"):
        raise HTTPException(415, "contenu incompatible avec le type déclaré")
    upload_id = uuid.uuid4().hex[:16]
    dest = UPLOADS_DIR / f"{upload_id}.{ext}"
    dest.write_bytes(data)
    with db() as conn:
        conn.execute(
            "INSERT INTO uploads (id, filename, path, mime, created_at) VALUES (?,?,?,?,?)",
            (upload_id, body.get("filename") or f"{upload_id}.{ext}", str(dest), mime,
             time.strftime("%Y-%m-%dT%H:%M:%S")),
        )
    # Le worker télécharge via /worker/files/<id>.
    return {"id": upload_id, "path": f"hub://{upload_id}"}


# ------------------------------------------------------- worker pull API

def touch_heartbeat(info: Optional[dict] = None):
    with db() as conn:
        conn.execute(
            "INSERT INTO worker_state (key, value, updated_at) VALUES ('heartbeat','',?) "
            "ON CONFLICT(key) DO UPDATE SET updated_at=excluded.updated_at",
            (time.time(),),
        )
        if info is not None:
            conn.execute(
                "INSERT INTO worker_state (key, value, updated_at) VALUES ('info',?,?) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at",
                (json.dumps(info), time.time()),
            )


STALE_RUNNING_SECONDS = 15 * 60


def recover_stale_jobs(conn):
    """Les jobs 'running' sans signe de vie = agent tué/redémarré."""
    rows = conn.execute(
        "SELECT id FROM worker_jobs WHERE status='running' AND updated_at<?",
        (time.time() - STALE_RUNNING_SECONDS,)).fetchall()
    for r in rows:
        conn.execute("UPDATE worker_jobs SET status='failed', "
                     "error='agent interrompu (redémarrage), relancez le job', "
                     "updated_at=? WHERE id=?", (time.time(), r["id"]))
        emit_local("jobFailed", {"job_id": r["id"],
                                 "message": "agent interrompu (redémarrage), relancez le job"})
    if rows:
        emit_local("queueChanged", {})
    return len(rows)


@app.get("/api/v1/worker/jobs/next")
def worker_next(request: Request):
    require_worker(request)
    touch_heartbeat()
    with db() as conn:
        recover_stale_jobs(conn)
        row = conn.execute(
            "SELECT * FROM worker_jobs WHERE status='queued' ORDER BY created_at ASC LIMIT 1"
        ).fetchone()
        if not row:
            return JSONResponse({"job": None})
        conn.execute("UPDATE worker_jobs SET status='running', updated_at=? WHERE id=?",
                     (time.time(), row["id"]))
    emit_local("jobStarted", {"job_id": row["id"], "family": "flux",
                              "total_steps": json.loads(row["params_json"] or "{}").get("steps", 4)})
    emit_local("queueChanged", {})
    return {"job": {"id": row["id"], "params": json.loads(row["params_json"] or "{}")}}


@app.get("/api/v1/worker/jobs/{job_id}/status")
def worker_job_status(job_id: str, request: Request):
    require_worker(request)
    touch_heartbeat()
    with db() as conn:
        row = conn.execute(
            "SELECT status, cancel_requested FROM worker_jobs WHERE id=?", (job_id,)).fetchone()
    if not row:
        raise HTTPException(404, "not found")
    return {"status": row["status"], "cancel_requested": bool(row["cancel_requested"])}


@app.post("/api/v1/worker/jobs/{job_id}/progress")
def worker_progress(job_id: str, request: Request, body: dict):
    require_worker(request)
    touch_heartbeat()
    step, total = int(body.get("step") or 0), int(body.get("total") or 0)
    preview_b64 = body.get("preview_b64")
    phase = body.get("phase")
    eff_w, eff_h = body.get("width"), body.get("height")
    with db() as conn:
        conn.execute(
            "UPDATE worker_jobs SET progress_json=?, updated_at=? WHERE id=?",
            (json.dumps({"step": step, "total": total, "phase": phase}), time.time(), job_id),
        )
        if eff_w and eff_h:
            row = conn.execute("SELECT params_json FROM worker_jobs WHERE id=?",
                               (job_id,)).fetchone()
            if row:
                try:
                    params = json.loads(row["params_json"] or "{}")
                except Exception:
                    params = {}
                params["width"], params["height"] = int(eff_w), int(eff_h)
                conn.execute("UPDATE worker_jobs SET params_json=? WHERE id=?",
                             (json.dumps(params), job_id))
    if preview_b64:
        try:
            (PREVIEWS_DIR / f"{job_id}.jpg").write_bytes(base64.b64decode(preview_b64))
            emit_local("jobPreview", {"job_id": job_id,
                                      "jpeg_base64": preview_b64,
                                      "step": step, "total_steps": total})
        except Exception:
            pass
    evt = {"job_id": job_id, "step": step, "total_steps": total}
    if phase:
        evt["phase"] = phase
    emit_local("jobProgress", evt)
    return {"ok": True}


@app.post("/api/v1/worker/jobs/{job_id}/complete")
def worker_complete(job_id: str, request: Request, body: dict):
    require_worker(request)
    touch_heartbeat()
    try:
        image_bytes = base64.b64decode(body.get("image_b64", ""))
    except Exception:
        raise HTTPException(400, "image_b64 invalide")
    if not image_bytes:
        raise HTTPException(400, "image vide")
    with db() as conn:
        row = conn.execute("SELECT params_json FROM worker_jobs WHERE id=?", (job_id,)).fetchone()
        if not row:
            raise HTTPException(404, "not found")
        params = json.loads(row["params_json"] or "{}")
        image_id = uuid.uuid4().hex[:16]
        dest = IMAGES_DIR / f"{image_id}.png"
        dest.write_bytes(image_bytes)
        seed = body.get("seed", params.get("seed"))
        if body.get("enhanced_prompt"):
            params = dict(params, enhanced_prompt=body["enhanced_prompt"])
        conn.execute(
            """INSERT INTO images (id, filename, path, board, source, prompt,
               negative_prompt, model, seed, width, height, steps, guidance,
               meta_json, created_at)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (image_id, f"{image_id}.png", str(dest), params.get("board") or "Default",
             "generation", params.get("prompt"), params.get("negative_prompt"),
             params.get("model") or "flux2-klein-4b", seed, params.get("width"),
             params.get("height"), params.get("steps"), params.get("guidance"),
             json.dumps(params), time.strftime("%Y-%m-%dT%H:%M:%S")),
        )
        conn.execute(
            "UPDATE worker_jobs SET status='completed', output_image_id=?, updated_at=? WHERE id=?",
            (image_id, time.time(), job_id),
        )
    (PREVIEWS_DIR / f"{job_id}.jpg").unlink(missing_ok=True)
    emit_local("jobCompleted", {"job_id": job_id, "family": "flux",
                                "image_id": image_id, "seed": seed})
    emit_local("queueChanged", {})
    return {"ok": True, "image_id": image_id}


@app.post("/api/v1/worker/jobs/{job_id}/fail")
def worker_fail(job_id: str, request: Request, body: dict):
    require_worker(request)
    touch_heartbeat()
    error = body.get("error") or "échec inconnu"
    if error == "__cancelled__":
        with db() as conn:
            conn.execute("UPDATE worker_jobs SET status='cancelled', updated_at=? WHERE id=?",
                         (time.time(), job_id))
        emit_local("jobCancelled", {"job_id": job_id})
    else:
        with db() as conn:
            conn.execute("UPDATE worker_jobs SET status='failed', error=?, updated_at=? WHERE id=?",
                         (error, time.time(), job_id))
        emit_local("jobFailed", {"job_id": job_id, "message": error})
    emit_local("queueChanged", {})
    return {"ok": True}


@app.post("/api/v1/worker/heartbeat")
def worker_heartbeat(request: Request, body: dict):
    require_worker(request)
    touch_heartbeat(body)
    return {"ok": True}


@app.get("/api/v1/worker/files/{upload_id}")
def worker_file(upload_id: str, request: Request):
    require_worker(request)
    with db() as conn:
        row = conn.execute("SELECT path, mime FROM uploads WHERE id=?", (upload_id,)).fetchone()
    if not row or not Path(row["path"]).exists():
        raise HTTPException(404, "not found")
    return FileResponse(row["path"], media_type=row["mime"] or "image/png")


# -------------------------------------------------------------------- SSE

@app.get("/api/v1/events")
def events(request: Request):
    require_auth(request)

    def stream():
        q: queue.Queue = queue.Queue()
        with EVENT_LOCK:
            EVENT_QUEUES.append(q)
        try:
            while True:
                try:
                    yield q.get(timeout=20)
                except queue.Empty:
                    yield ": keepalive\r\n\r\n"
        finally:
            with EVENT_LOCK:
                if q in EVENT_QUEUES:
                    EVENT_QUEUES.remove(q)

    return StreamingResponse(stream(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-store",
                                      "X-Accel-Buffering": "no"})


# ------------------------------------------------------------ gallery (DB)

@app.get("/api/v1/history")
def history(request: Request):
    require_auth(request)
    with db() as conn:
        rows = conn.execute(
            "SELECT * FROM images ORDER BY created_at DESC, id DESC LIMIT 200").fetchall()
    return [image_dto(row) for row in rows]


def image_dto(row):
    try:
        meta_extra = json.loads(row["meta_json"] or "{}")
    except Exception:
        meta_extra = {}
    return {
        "id": row["id"],
        "url": f"/api/v1/images/{row['id']}",
        "thumbnail_url": f"/api/v1/images/{row['id']}",
        "filename": row["filename"],
        "board": row["board"],
        "family": "flux",
        "modified_at": row["created_at"],
        "flag": row["flag"],
        "rating": row["rating"],
        "metadata": {
            "prompt": row["prompt"], "negative_prompt": row["negative_prompt"],
            "model": row["model"], "seed": row["seed"], "steps": row["steps"],
            "guidance": row["guidance"], "width": row["width"], "height": row["height"],
            "quantize": None, "loras": [],
            "enhanced_prompt": meta_extra.get("enhanced_prompt"),
        },
    }


@app.get("/api/v1/images/{image_id}")
def get_image(image_id: str, request: Request):
    require_auth(request)
    with db() as conn:
        row = conn.execute("SELECT path FROM images WHERE id=?", (image_id,)).fetchone()
    if not row or not Path(row["path"]).exists():
        raise HTTPException(404, "not found")
    return FileResponse(row["path"], media_type="image/png")


@app.post("/api/v1/gallery/import")
def gallery_import(request: Request, body: dict):
    """Importe une image existante dans la galerie (comparatifs, archives)."""
    require_auth(request)
    try:
        data = base64.b64decode(body.get("image_b64", ""))
    except Exception:
        raise HTTPException(400, "image_b64 invalide")
    if not data:
        raise HTTPException(400, "image vide")
    image_id = uuid.uuid4().hex[:16]
    filename = body.get("filename") or f"{image_id}.png"
    filename = Path(filename).name
    if not filename.lower().endswith((".png", ".jpg", ".jpeg", ".webp")):
        filename += ".png"
    dest = IMAGES_DIR / f"{image_id}_{filename}"
    dest.write_bytes(data)
    with db() as conn:
        conn.execute(
            """INSERT INTO images (id, filename, path, board, source, prompt,
               model, seed, width, height, steps, guidance,
               meta_json, created_at)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (image_id, filename, str(dest), body.get("board") or "Imports",
             body.get("source") or "import", body.get("prompt"), body.get("model"),
             body.get("seed"), body.get("width"), body.get("height"),
             body.get("steps"), body.get("guidance"),
             json.dumps(body.get("meta") or {}),
             time.strftime("%Y-%m-%dT%H:%M:%S")),
        )
    return {"ok": True, "image_id": image_id}


@app.post("/api/v1/gallery/{image_id}/flag")
def flag_image(image_id: str, request: Request, body: dict):
    require_auth(request)
    with db() as conn:
        conn.execute("UPDATE images SET flag=? WHERE id=?", (body.get("flag"), image_id))
    return {"ok": True}


@app.post("/api/v1/gallery/{image_id}/rating")
def rate_image(image_id: str, request: Request, body: dict):
    require_auth(request)
    with db() as conn:
        conn.execute("UPDATE images SET rating=? WHERE id=?",
                     (int(body.get("rating") or 0), image_id))
    return {"ok": True}


@app.delete("/api/v1/gallery/{image_id}")
def delete_image(image_id: str, request: Request):
    require_auth(request)
    with db() as conn:
        row = conn.execute("SELECT path FROM images WHERE id=?", (image_id,)).fetchone()
        conn.execute("DELETE FROM images WHERE id=?", (image_id,))
    if row:
        Path(row["path"]).unlink(missing_ok=True)
    return {"ok": True}


@app.post("/api/v1/gallery/{image_id}/reuse")
@app.post("/api/v1/gallery/{image_id}/variation")
def reuse(image_id: str, request: Request):
    require_auth(request)
    variation = request.url.path.endswith("/variation")
    with db() as conn:
        row = conn.execute("SELECT * FROM images WHERE id=?", (image_id,)).fetchone()
    if not row:
        raise HTTPException(404, "not found")
    payload = {
        "prompt": row["prompt"], "model": row["model"], "width": row["width"],
        "height": row["height"], "steps": row["steps"], "guidance": row["guidance"],
    }
    if variation:
        payload["seed"] = secrets.randbelow(2**31)
    job_id = uuid.uuid4().hex[:12]
    with db() as conn:
        conn.execute(
            """INSERT INTO worker_jobs
               (id, kind, params_json, status, created_at, updated_at)
               VALUES (?,?,?,?,?,?)""",
            (job_id, "generate", json.dumps(payload), "queued",
             time.strftime("%Y-%m-%dT%H:%M:%S"), time.time()),
        )
    emit_local("jobCreated", {"job_id": job_id, "family": "flux"})
    emit_local("queueChanged", {})
    return {"ok": True, "job_id": job_id}


# ---------------------------------------------------------------- upscale

@app.get("/api/v1/upscale/models")
def upscale_models(request: Request):
    require_auth(request)
    return JSONResponse(UPSCALE_MODELS)


@app.get("/api/v1/upscale/recommendations")
def upscale_recommendations(request: Request, width: int = 0, height: int = 0,
                            image_id: str = "", model: str = ""):
    require_auth(request)
    w, h = width, height
    if not w or not h:
        if image_id:
            with db() as conn:
                row = conn.execute(
                    "SELECT width, height FROM images WHERE id=?", (image_id,)).fetchone()
            if row:
                w, h = row["width"] or 0, row["height"] or 0
        if not w or not h:
            raise HTTPException(400, "width/height ou image_id requis")
    scale = 2 if "x2" in (model or "").lower() else 4
    return JSONResponse([
        {"label": f"Natif ×{scale}", "width": w * scale, "height": h * scale,
         "note": "Real-ESRGAN natif.", "recommended": w * scale <= 4096},
        {"label": "×2", "width": w * 2, "height": h * 2,
         "note": "Plus fidèle à la source.", "recommended": False},
    ])


@app.get("/api/v1/upscale/jobs")
def upscale_jobs(request: Request):
    require_auth(request)
    return JSONResponse([])


@app.post("/api/v1/upscale/jobs")
def upscale_start(request: Request, body: dict):
    require_auth(request)
    raise HTTPException(503, "upscale non disponible sur ce worker pour l'instant")


# ------------------------------------------------------------------ static

DIST = Path(os.environ.get("WEBUI_DIST", "/srv/webui"))


@app.get("/")
def index():
    # Jamais de cache sur index.html : c'est lui qui référence le bundle
    # JS hashé (les assets sous /assets/, eux, sont immuables).
    return FileResponse(DIST / "index.html",
                        headers={"Cache-Control": "no-store, must-revalidate"})


app.mount("/", StaticFiles(directory=DIST, html=True), name="webui")

"""MLXBits Image Studio — hub Proxmox.

Sert le frontend statique, gère l'authentification (login utilisateur/mot de
passe), stocke les images et leurs métadonnées (SQLite + volume), et pilote
le worker mflux sur la Mac mini via NetBird (proxy API + SSE).

Le navigateur ne parle qu'au hub. La mini n'est jamais exposée.
"""
import json
import os
import secrets
import sqlite3
import threading
import time
import uuid
from pathlib import Path

import requests
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles

DATA = Path(os.environ.get("STUDIO_DATA", "/data"))
IMAGES_DIR = DATA / "images"
UPLOADS_DIR = DATA / "uploads"
DB_PATH = DATA / "studio.db"
# Plusieurs URLs possibles (NetBird + LAN), séparées par des virgules :
# le hub essaie chacune jusqu'à ce qu'une réponde.
WORKER_URLS = [
    u.strip().rstrip("/")
    for u in os.environ.get(
        "WORKER_URL", "http://100.102.122.144:8899"
    ).split(",")
    if u.strip()
]
WORKER_TOKEN = os.environ.get("WORKER_TOKEN", "klein-4b")
ADMIN_USER = os.environ.get("ADMIN_USER", "admin")
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "studio")
COOKIE = "studio_session"
SESSION_TTL = 30 * 24 * 3600  # 30 jours

for d in (DATA, IMAGES_DIR, UPLOADS_DIR):
    d.mkdir(parents=True, exist_ok=True)

app = FastAPI(title="MLXBits Image Studio hub")


# ------------------------------------------------------------------ storage

def db():
    conn = sqlite3.connect(DB_PATH)
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
            """
        )


init_db()


def worker_headers():
    return {"Authorization": "Bearer " + WORKER_TOKEN}


class WorkerUnreachable(Exception):
    pass


def worker(method: str, path: str, **kwargs):
    last_error: Exception | None = None
    for base in WORKER_URLS:
        try:
            return requests.request(method, base + path, headers=worker_headers(),
                                    timeout=kwargs.pop("timeout", 12), **kwargs)
        except requests.RequestException as exc:
            last_error = exc
    raise WorkerUnreachable(str(last_error))


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


# ------------------------------------------------------ proxied worker API

PASS_THROUGH_GET = ("/api/v1/status", "/api/v1/capabilities", "/api/v1/models",
                    "/api/v1/queue", "/api/v1/presets")


@app.get("/api/v1/status")
def status():
    try:
        r = worker("GET", "/api/v1/status")
        return JSONResponse(r.json())
    except Exception as exc:
        return JSONResponse({
            "app": "MLXBits Image Studio", "remoteAccess": {"is_running": False},
            "system": {}, "queue": {},
            "worker_error": str(exc),
        })


@app.get("/api/v1/capabilities")
def capabilities():
    return JSONResponse(worker("GET", "/api/v1/capabilities").json())


@app.get("/api/v1/models")
def models():
    return JSONResponse(worker("GET", "/api/v1/models").json())


@app.get("/api/v1/queue")
def queue(request: Request):
    require_auth(request)
    return JSONResponse(worker("GET", "/api/v1/queue").json())


@app.get("/api/v1/jobs/{job_id}")
def get_job(job_id: str, request: Request):
    require_auth(request)
    return JSONResponse(worker("GET", f"/api/v1/jobs/{job_id}").json())


@app.get("/api/v1/jobs/{job_id}/preview")
def job_preview(job_id: str, request: Request):
    require_auth(request)
    r = worker("GET", f"/api/v1/jobs/{job_id}/preview", timeout=60)
    return Response(r.content, media_type=r.headers.get("Content-Type", "image/png"))


@app.post("/api/v1/generate")
def generate(request: Request, body: dict):
    require_auth(request)
    r = worker("POST", "/api/v1/generate", json=body)
    return JSONResponse(r.json(), status_code=r.status_code)


@app.post("/api/v1/jobs/{job_id}/cancel")
def cancel_job(job_id: str, request: Request):
    require_auth(request)
    r = worker("POST", f"/api/v1/jobs/{job_id}/cancel")
    return JSONResponse(r.json(), status_code=r.status_code)


@app.post("/api/v1/uploads")
def uploads(request: Request, body: dict):
    require_auth(request)
    # Forwarded to the worker (edit mode needs worker-local paths) and kept
    # locally for the archive.
    r = worker("POST", "/api/v1/uploads", json=body, timeout=120)
    if r.status_code == 200:
        import base64
        raw = body.get("data_base64", "")
        try:
            data = base64.b64decode(raw)
            ext = {"image/png": "png", "image/jpeg": "jpg", "image/webp": "webp"}.get(
                (body.get("mime") or "").lower(), "png")
            dest = UPLOADS_DIR / f"{uuid.uuid4().hex}.{ext}"
            dest.write_bytes(data)
        except Exception:
            pass
    return JSONResponse(r.json(), status_code=r.status_code)


# ------------------------------------------------------------- SSE pipeline

@app.get("/api/v1/events")
def events(request: Request):
    require_auth(request)

    def stream():
        import base64 as b64
        connected = None
        last_error = None
        for base in WORKER_URLS:
            try:
                connected = requests.get(base + "/api/v1/events", headers=worker_headers(),
                                         stream=True, timeout=(10, None))
                break
            except requests.RequestException as exc:
                last_error = exc
        if connected is None:
            yield f"event: jobFailed\ndata: {json.dumps({'message': f'worker injoignable: {last_error}'})}\r\n\r\n"
            return
        with connected as upstream:
            event_name = None
            for raw in upstream.iter_lines(decode_unicode=True):
                if raw is None:
                    continue
                line = raw.rstrip("\r")
                if line.startswith("event: "):
                    event_name = line[7:].strip()
                    continue
                if line.startswith("data: ") and event_name:
                    payload = line[6:]
                    if event_name == "jobCompleted":
                        try:
                            data = json.loads(payload)
                            image_id = persist_completed_image(data, b64)
                            data["image_id"] = image_id
                            payload = json.dumps(data)
                        except Exception:
                            pass
                    yield f"event: {event_name}\ndata: {payload}\r\n\r\n"
                    event_name = None
                elif line == "":
                    continue
                else:
                    yield raw + "\r\n"

    return StreamingResponse(stream(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-store",
                                      "X-Accel-Buffering": "no"})


def persist_completed_image(data: dict, b64) -> str:
    """On jobCompleted: fetch the final image from the worker, store it in the
    Proxmox volume + DB, return the hub image id."""
    job_id = data.get("job_id")
    image_id = uuid.uuid4().hex[:16]
    r = worker("GET", f"/api/v1/jobs/{job_id}/preview", timeout=120)
    if r.status_code != 200:
        return ""
    dest = IMAGES_DIR / f"{image_id}.png"
    dest.write_bytes(r.content)

    meta = {}
    try:
        meta = worker("GET", f"/api/v1/jobs/{job_id}").json()
    except Exception:
        pass
    params = meta or {}
    with db() as conn:
        conn.execute(
            """INSERT INTO images (id, filename, path, board, source, prompt,
               negative_prompt, model, seed, width, height, steps, guidance,
               meta_json, created_at)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (image_id, f"{image_id}.png", str(dest), params.get("board") or "Default",
             "generation", params.get("prompt"), None, params.get("model"),
             params.get("resolved_seed") or params.get("seed"), params.get("width"),
             params.get("height"), params.get("steps"), params.get("guidance"),
             json.dumps(params), time.strftime("%Y-%m-%dT%H:%M:%S")),
        )
    return image_id


# ------------------------------------------------------------ gallery (DB)

@app.get("/api/v1/history")
def history(request: Request):
    require_auth(request)
    with db() as conn:
        rows = conn.execute(
            "SELECT * FROM images ORDER BY created_at DESC, id DESC LIMIT 200").fetchall()
    return [image_dto(row) for row in rows]


def image_dto(row):
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
def reuse(image_id: str, request: Request, body: dict = None):
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
    r = worker("POST", "/api/v1/generate", json=payload)
    return JSONResponse(r.json(), status_code=r.status_code)


# ------------------------------------------------------------------ static

DIST = Path(os.environ.get("WEBUI_DIST", "/srv/webui"))


@app.get("/")
def index():
    return FileResponse(DIST / "index.html")


app.mount("/", StaticFiles(directory=DIST, html=True), name="webui")

#!/usr/bin/env python3
"""MLXBits Image Studio — Mac mini worker (/api/v1 subset).

The "brain": drives mflux locally (text-to-image + edit) and exposes the
fork's /api/v1 contract. The Proxmox hub proxies browser traffic here over
NetBird; the worker never faces the internet directly.

Runs inside the mflux venv (~/mflux-env/bin/python) so Pillow is available
for preview downscaling. Python 3.9 compatible.
"""
import base64
import json
import os
import queue
import re
import shutil
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

BASE = Path.home() / "mflux-api"
CONFIG_PATH = BASE / "config.json"
UPLOADS = BASE / "uploads"
STEPWISE_ROOT = BASE / "stepwise"
DEFAULT_CONFIG = {
    "host": "0.0.0.0",
    "port": 8899,
    "token": "klein-4b",
    "output_dir": str(BASE / "outputs"),
    "mflux_bin": str(Path.home() / "mflux-env/bin"),
    "model_repo": "ar9av/FLUX.2-klein-4B-mflux-4bit",
    "base_model": "flux2-klein-4b",
}

MIME = {"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "webp": "image/webp", "json": "application/json"}

MODELS = [
    {"id": "flux2-klein-4b", "family": "flux", "display_name": "FLUX.2 Klein 4B",
     "is_distilled": True, "default_steps": 4, "default_guidance": 1.0,
     "supports_negative_prompt": False, "recommended_quantize": 8,
     "approximate_size_gb": 4.6},
    {"id": "flux2-klein-9b", "family": "flux", "display_name": "FLUX.2 Klein 9B",
     "is_distilled": True, "default_steps": 4, "default_guidance": 1.0,
     "supports_negative_prompt": False, "recommended_quantize": 8,
     "approximate_size_gb": 9.8},
]

CONFIG = {}
JOBS = {}            # id -> job dict
JOB_LOCK = threading.Lock()
GEN_LOCK = threading.Lock()   # one generation at a time on the ANE/GPU
EVENT_QUEUES = []
SESSIONS = {}  # token -> created_at
SESSION_TTL = 30 * 24 * 3600  # 30 jours
SESSION_LOCK = threading.Lock()


def load_config():
    global CONFIG
    BASE.mkdir(parents=True, exist_ok=True)
    UPLOADS.mkdir(parents=True, exist_ok=True)
    STEPWISE_ROOT.mkdir(parents=True, exist_ok=True)
    if CONFIG_PATH.exists():
        CONFIG = json.loads(CONFIG_PATH.read_text())
    else:
        CONFIG = dict(DEFAULT_CONFIG)
        CONFIG_PATH.write_text(json.dumps(CONFIG, indent=2))
    Path(CONFIG["output_dir"]).mkdir(parents=True, exist_ok=True)


def emit(event, payload):
    with JOB_LOCK:
        for q in list(EVENT_QUEUES):
            q.put((event, payload))


def sse_frame(event, payload):
    return ("event: %s\ndata: %s\r\n\r\n" % (event, json.dumps(payload))).encode()


def downscale_jpeg(path, max_edge=512, quality=0.6):
    try:
        from PIL import Image
        img = Image.open(path)
        img.thumbnail((max_edge, max_edge))
        buf = io.BytesIO()
        img.convert("RGB").save(buf, "JPEG", quality=int(quality * 100))
        return buf.getvalue()
    except Exception:
        return None


import io  # noqa: E402  (used by downscale_jpeg)


# ---------------------------------------------------------------- generation

STEP_RE = re.compile(r"(\d+)/(\d+)")


def run_generation(job):
    """Blocking mflux run with SSE progress + stepwise previews."""
    cfg = CONFIG
    bin_dir = cfg["mflux_bin"]
    edit = bool(job["params"].get("edit_mode"))
    binary = "mflux-generate-flux2-edit" if edit else "mflux-generate-flux2"
    p = job["params"]
    stepwise = STEPWISE_ROOT / job["id"]
    stepwise.mkdir(parents=True, exist_ok=True)
    output_dir = Path(cfg["output_dir"]) / (p.get("board") or "Default")
    output_dir.mkdir(parents=True, exist_ok=True)
    out_file = output_dir / ("%s.png" % job["id"])

    args = [
        os.path.join(bin_dir, binary),
        "--model", cfg["model_repo"],
        "--base-model", cfg["base_model"],
        "--prompt", p.get("prompt", ""),
        "--width", str(p.get("width", 512)),
        "--height", str(p.get("height", 512)),
        "--steps", str(p.get("steps", 4)),
        "--guidance", str(p.get("guidance", 1.0)),
        "--seed", str(p.get("seed") if p.get("seed") is not None else int(time.time())),
        "--output", str(out_file),
        "--stepwise-image-output-dir", str(stepwise),
        "--metadata",
    ]
    if not edit and p.get("negative_prompt"):
        args += ["--negative-prompt", p["negative_prompt"]]
    if edit:
        for img in p.get("edit_image_paths", []):
            args += ["--image-paths", img]

    job["output_path"] = str(out_file)
    watcher_stop = threading.Event()
    watcher = threading.Thread(target=watch_stepwise, args=(job, stepwise, watcher_stop), daemon=True)
    watcher.start()

    try:
        proc = subprocess.Popen(
            args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1,
        )
        job["process"] = proc
        for line in proc.stdout:
            job["log"] = (job.get("log", "") + line)[-8000:]
            m = STEP_RE.search(line)
            if m:
                step, total = int(m.group(1)), int(m.group(2))
                if total and step <= total:
                    job["current_step"], job["total_steps"] = step, total
                    emit("jobProgress", {"job_id": job["id"], "step": step,
                                         "total_steps": total})
        code = proc.wait()
        watcher_stop.set()
        watcher.join(timeout=2)

        if code == 0 and out_file.exists():
            job["status"] = "completed"
            job["completed_at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
            job["output_paths"] = [str(out_file)]
            emit("jobCompleted", {"job_id": job["id"], "family": "flux",
                                  "output_path": str(out_file),
                                  "seed": p.get("seed")})
            emit("queueChanged", {})
        else:
            job["status"] = "failed"
            job["error"] = "mflux exit %s" % code
            emit("jobFailed", {"job_id": job["id"], "message": job["error"]})
    except Exception as exc:
        watcher_stop.set()
        job["status"] = "failed"
        job["error"] = str(exc)
        emit("jobFailed", {"job_id": job["id"], "message": str(exc)})
    finally:
        shutil.rmtree(stepwise, ignore_errors=True)
        GEN_LOCK.release()


def watch_stepwise(job, stepwise_dir, stop):
    seen = set()
    while not stop.is_set():
        try:
            frames = sorted(stepwise_dir.glob("*.png"), key=lambda p: p.stat().st_mtime)
            newest = frames[-1] if frames else None
            if newest and newest.name not in seen:
                # mflux writes progressively; wait until the file stops growing
                size1 = newest.stat().st_size
                time.sleep(0.4)
                if newest.stat().st_size == size1 or newest.stat().st_size > size1:
                    seen.add(newest.name)
                    jpeg = downscale_jpeg(newest)
                    if jpeg:
                        emit("jobPreview", {"job_id": job["id"],
                                            "jpeg_base64": base64.b64encode(jpeg).decode()})
        except Exception:
            pass
        stop.wait(0.5)


def start_job(params):
    jid = uuid.uuid4().hex[:12]
    job = {
        "id": jid, "status": "running", "family": "flux",
        "params": params, "created_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "current_step": 0, "total_steps": int(params.get("steps", 4)),
        "log": "", "output_paths": [],
    }
    with JOB_LOCK:
        JOBS[jid] = job
    emit("jobCreated", {"job_id": jid, "family": "flux"})
    emit("queueChanged", {})

    def runner():
        GEN_LOCK.acquire()
        emit("jobStarted", {"job_id": jid, "family": "flux", "total_steps": job["total_steps"]})
        run_generation(job)

    threading.Thread(target=runner, daemon=True).start()
    return jid


# ------------------------------------------------------------------- gallery

def file_id(path):
    return uuid.uuid5(uuid.NAMESPACE_URL, path).hex


def gallery_items():
    out_dir = Path(CONFIG["output_dir"])
    items = []
    for png in sorted(out_dir.rglob("*.png"), key=lambda p: p.stat().st_mtime, reverse=True)[:80]:
        board = png.parent.name if png.parent != out_dir else "Default"
        meta = {}
        sidecar = png.with_suffix(".json")
        if sidecar.exists():
            try:
                meta = json.loads(sidecar.read_text())
            except Exception:
                meta = {}
        items.append({"id": file_id(str(png)), "path": str(png), "board": board,
                      "filename": png.name, "meta": meta})
    return items


# -------------------------------------------------------------------- server

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    # -- helpers ---------------------------------------------------------
    def body_json(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
            return json.loads(self.rfile.read(length) or b"{}")
        except Exception:
            return {}

    def send_json(self, obj, status=200, headers=None):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def send_file(self, path, cache=300):
        p = Path(path)
        if not p.exists():
            return self.send_json({"error": "not found"}, 404)
        data = p.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", MIME.get(p.suffix.lstrip("."), "application/octet-stream"))
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "private, max-age=%d" % cache)
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        auth = self.headers.get("Authorization", "")
        if auth == "Bearer " + CONFIG["token"]:
            return True
        cookie = self.headers.get("Cookie", "")
        for part in cookie.split(";"):
            if part.strip().startswith("mlxbits_worker="):
                token = part.strip().split("=", 1)[1]
                with SESSION_LOCK:
                    created = SESSIONS.get(token)
                if created and time.time() - created < SESSION_TTL:
                    return True
        return False

    # -- routing ---------------------------------------------------------
    def do_GET(self):
        u = urlparse(self.path)
        path, q = u.path, parse_qs(u.query)
        if path == "/api/v1/auth/login":
            return self.send_json({"error": "POST requis"}, 405)
        if path == "/api/v1/events":
            if not self.authorized():
                return self.send_json({"error": "unauthorized"}, 401)
            return self.sse()
        if path in ("/api/v1/auth/me",):
            ok = self.authorized()
            return self.send_json({"username": "admin"} if ok else {"error": "unauthorized"},
                                  200 if ok else 401)
        if not path.startswith("/api/v1/"):
            return self.send_json({"error": "not found"}, 404)
        if not self.authorized():
            return self.send_json({"error": "unauthorized"}, 401)
        if path == "/api/v1/status":
            return self.status()
        if path == "/api/v1/capabilities":
            return self.capabilities()
        if path == "/api/v1/models":
            return self.send_json(MODELS)
        if path == "/api/v1/queue":
            with JOB_LOCK:
                return self.send_json([self.job_dto(j) for j in JOBS.values()])
        if path.startswith("/api/v1/jobs/"):
            jid = path.split("/")[4]
            with JOB_LOCK:
                job = JOBS.get(jid)
            if not job:
                return self.send_json({"error": "not found"}, 404)
            if path.endswith("/preview"):
                latest = job.get("output_paths") or []
                if job["status"] == "completed" and latest:
                    return self.send_file(latest[-1], cache=0)
                return self.send_json({"error": "no preview yet"}, 404)
            return self.send_json(self.job_dto(job))
        if path == "/api/v1/history":
            return self.send_json([self.gallery_dto(g) for g in gallery_items()])
        if path.startswith("/api/v1/images/"):
            gid = path.split("/")[-1]
            for g in gallery_items():
                if g["id"] == gid:
                    return self.send_file(g["path"])
            return self.send_json({"error": "not found"}, 404)
        if path == "/api/v1/presets":
            return self.send_json({"templates": [], "model_defaults": []})
        if path == "/api/v1/upscale/models":
            return self.send_json([])
        if path == "/api/v1/upscale/jobs":
            return self.send_json([])
        if path == "/api/v1/upscale/recommendations":
            try:
                w = int(q.get("width", ["0"])[0]); h = int(q.get("height", ["0"])[0])
            except ValueError:
                return self.send_json({"error": "width/height requis"}, 400)
            if w < 8 or h < 8:
                return self.send_json({"error": "width/height requis"}, 400)
            recs = [
                {"label": "Natif ×4", "width": w * 4, "height": h * 4,
                 "note": "Real-ESRGAN ×4 (non installé sur ce worker)", "recommended": w * 4 <= 4096},
                {"label": "×2", "width": w * 2, "height": h * 2,
                 "note": "Plus fidèle à la source.", "recommended": False},
            ]
            return self.send_json(recs)
        return self.send_json({"error": "not found"}, 404)

    def do_POST(self):
        u = urlparse(self.path)
        path = u.path
        if path == "/api/v1/auth/login":
            body = self.body_json()
            presented = body.get("password") or body.get("token") or ""
            if presented == CONFIG["token"]:
                sid = uuid.uuid4().hex
                with SESSION_LOCK:
                    now = time.time()
                    SESSIONS[sid] = now
                    expired = [k for k, v in SESSIONS.items() if now - v >= SESSION_TTL]
                    for k in expired:
                        del SESSIONS[k]
                max_age = str(SESSION_TTL)
                return self.send_json(
                    {"ok": True, "username": "admin"},
                    headers={"Set-Cookie": "mlxbits_worker=%s; Path=/; HttpOnly; SameSite=Lax; Max-Age=%s" % (sid, max_age)},
                )
            return self.send_json({"error": "identifiants invalides"}, 401)
        if path == "/api/v1/auth/logout":
            return self.send_json({"ok": True},
                                  headers={"Set-Cookie": "mlxbits_worker=; Path=/; Max-Age=0"})
        if not path.startswith("/api/v1/"):
            return self.send_json({"error": "not found"}, 404)
        if not self.authorized():
            return self.send_json({"error": "unauthorized"}, 401)
        if path == "/api/v1/generate":
            body = self.body_json()
            prompt = (body.get("prompt") or "").strip()
            if not prompt:
                return self.send_json({"error": "prompt requis"}, 400)
            if body.get("edit_mode"):
                paths = []
                for p in body.get("edit_image_paths", []):
                    sp = os.path.realpath(p)
                    if sp.startswith(str(UPLOADS) + "/") and os.path.exists(sp):
                        paths.append(sp)
                if not paths:
                    return self.send_json({"error": "edit_image_paths requis (uploads)"}, 400)
                body["edit_image_paths"] = paths[:4]
            jid = start_job(body)
            return self.send_json({"ok": True, "job_id": jid})
        if path == "/api/v1/uploads":
            body = self.body_json()
            import base64 as b64
            raw = body.get("data_base64", "")
            mime = (body.get("mime") or "").lower()
            ext = {"image/png": "png", "image/jpeg": "jpg", "image/webp": "webp"}.get(mime)
            if not ext:
                return self.send_json({"error": "mime non supporté"}, 415)
            try:
                data = b64.b64decode(raw)
            except Exception:
                return self.send_json({"error": "base64 invalide"}, 400)
            if len(data) > 20 * 1024 * 1024:
                return self.send_json({"error": "trop volumineux"}, 413)
            dest = UPLOADS / ("%s.%s" % (uuid.uuid4().hex, ext))
            dest.write_bytes(data)
            return self.send_json({"path": str(dest)})
        if path and path.startswith("/api/v1/jobs/") and path.endswith("/cancel"):
            jid = path.split("/")[4]
            with JOB_LOCK:
                job = JOBS.get(jid)
            if not job:
                return self.send_json({"error": "not found"}, 404)
            proc = job.get("process")
            if proc and proc.poll() is None:
                proc.terminate()
                job["status"] = "cancelled"
                emit("jobCancelled", {"job_id": jid})
                return self.send_json({"ok": True, "cancelled": "running"})
            if job["status"] == "running":
                job["status"] = "cancelled"
                emit("jobCancelled", {"job_id": jid})
            return self.send_json({"ok": True})
        return self.send_json({"error": "not found"}, 404)

    # -- endpoint bodies --------------------------------------------------
    def status(self):
        total_mem = 16.0
        try:
            total_mem = os.sysconf("HW_MEMSIZE") / 1073741824.0
        except (ValueError, OSError):
            pass
        try:
            disk = shutil.disk_usage(str(BASE))
            free_gb = round(disk.free / 1073741824.0, 1)
            total_disk = round(disk.total / 1073741824.0, 1)
        except OSError:
            free_gb = total_disk = None
        chip = "Apple Silicon"
        try:
            chip = subprocess.check_output(
                ["sysctl", "-n", "machdep.cpu.brand_string"]).decode().strip()
        except Exception:
            pass
        running = any(j["status"] == "running" for j in list(JOBS.values()))
        return self.send_json({
            "app": "MLXBits Image Studio — worker Mac mini",
            "remoteAccess": {"is_running": True, "allow_lan": True,
                             "require_auth": True, "connected_clients": len(EVENT_QUEUES)},
            "system": {
                "chip": chip, "chip_generation": "M1",
                "memory": {"total_gb": round(total_mem, 1), "pressure_ratio": None,
                           "swap_used_gb": None},
                "storage": {"free_gb": free_gb, "total_gb": total_disk},
                "loaded_model": CONFIG["model_repo"],
                "loaded_model_memory_gb": 4.8,
                "queue_length": 1 if running else 0,
                "versions": {"app": "worker-1.0", "mflux": "0.19.1", "mac_os": "26.5.1"},
            },
            "queue": {"pending": 1 if running else 0, "running_flux": running,
                      "running_krea2": False, "running_zimage": False},
        })

    def capabilities(self):
        return self.send_json({
            "families": [{"id": "flux", "display_name": "FLUX.2", "web_enqueue": True,
                          "supports_edit": True, "max_edit_images": 4}],
            "models": MODELS,
            "quantize_options": [0, 3, 4, 6, 8],
            "batch_limits": {"min": 1, "max": 4},
            "dimension_constraints": {"min_edge": 64, "max_edge": 2048, "multiple_of": 8},
            "timing_estimate_available": False,
        })

    def job_dto(self, j):
        p = j["params"]
        return {
            "id": j["id"], "family": "flux", "status": j["status"],
            "prompt": p.get("prompt"), "model": p.get("model") or "flux2-klein-4b",
            "width": p.get("width", 512), "height": p.get("height", 512),
            "steps": p.get("steps", 4), "guidance": p.get("guidance", 1.0),
            "seed": p.get("seed"), "resolved_seed": p.get("seed"),
            "current_step": j.get("current_step", 0),
            "total_steps": j.get("total_steps", 4),
            "progress": (j.get("current_step", 0) or 0) / max(j.get("total_steps", 4), 1),
            "has_image_input": bool(p.get("edit_mode")),
            "output_path": j.get("output_path"),
            "output_paths": j.get("output_paths", []),
            "board": p.get("board", "Default"),
            "created_at": j["created_at"],
            "preview_url": "/api/v1/jobs/%s/preview" % j["id"],
        }

    def gallery_dto(self, g):
        meta = g["meta"]
        return {
            "id": g["id"], "url": "/api/v1/images/" + g["id"],
            "thumbnail_url": "/api/v1/images/" + g["id"],
            "filename": g["filename"], "board": g["board"], "family": "flux",
            "modified_at": time.strftime("%Y-%m-%dT%H:%M:%S",
                                         time.localtime(Path(g["path"]).stat().st_mtime)),
            "flag": None, "rating": 0,
            "metadata": {
                "prompt": meta.get("prompt"), "negative_prompt": meta.get("negative_prompt"),
                "model": meta.get("model"), "seed": meta.get("seed"),
                "steps": meta.get("steps"), "guidance": meta.get("guidance"),
                "width": meta.get("width"), "height": meta.get("height"),
                "quantize": None, "loras": [],
            },
        }

    def sse(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        q = queue.Queue()
        with JOB_LOCK:
            EVENT_QUEUES.append(q)
        try:
            while True:
                try:
                    event, payload = q.get(timeout=15)
                    self.wfile.write(sse_frame(event, payload))
                except queue.Empty:
                    self.wfile.write(b": keepalive\r\n\r\n")
                self.wfile.flush()
        except Exception:
            pass
        finally:
            with JOB_LOCK:
                if q in EVENT_QUEUES:
                    EVENT_QUEUES.remove(q)


def main():
    load_config()
    server = ThreadingHTTPServer((CONFIG["host"], int(CONFIG["port"])), Handler)
    print("Worker mflux sur http://%s:%s (api/v1)" % (CONFIG["host"], CONFIG["port"]), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

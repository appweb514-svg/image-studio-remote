#!/usr/bin/env python3
"""Upscale x4 pour le mode rapide.

Priorité : `superscale` (Real-ESRGAN CoreML sur Neural Engine, ~3 s pour
512→2048). Repli : Real-ESRGAN torch/MPS (env realesrgan-env isolé).
"""
import glob
import os
import subprocess
import sys

SUPERSCALE_BIN = os.path.expanduser("~/.local/bin/superscale")
REALESRGAN_PY = os.path.expanduser("~/realesrgan-env/bin/python")
LOCAL_WEIGHTS = os.path.expanduser(
    "~/realesrgan-env/lib/python3.12/site-packages/weights/RealESRGAN_x4plus.pth")
REMOTE_WEIGHTS = ("https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/"
                  "RealESRGAN_x4plus.pth")


def upscale_superscale(inp, outdir, scale=4):
    proc = subprocess.run(
        [SUPERSCALE_BIN, "-s", str(scale), "-o", outdir, inp],
        capture_output=True, text=True, timeout=600,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"superscale exit {proc.returncode}: {proc.stderr[-300:]}")
    cands = sorted(glob.glob(os.path.join(outdir, "*.png")),
                   key=os.path.getmtime)
    if not cands:
        raise RuntimeError("superscale : aucun PNG produit")
    return cands[-1]


def upscale_torch(inp, out, scale=4, tile=256):
    import cv2
    from basicsr.archs.rrdbnet_arch import RRDBNet
    from realesrgan import RealESRGANer

    def pick_device():
        forced = os.environ.get("UPSCALE_DEVICE", "").lower()
        if forced in ("cpu", "mps"):
            return forced, forced == "mps"
        try:
            import torch
            if torch.backends.mps.is_available():
                return "mps", True
        except Exception:
            pass
        return "cpu", False

    model = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23,
                    num_grow_ch=32, scale=scale)
    device, half = pick_device()
    weights = LOCAL_WEIGHTS if os.path.exists(LOCAL_WEIGHTS) else REMOTE_WEIGHTS
    up = RealESRGANer(scale=scale, model_path=weights, model=model,
                      tile=tile, tile_pad=10, pre_pad=0,
                      half=half, device=device)
    print(f"repli torch device: {device} (half={half})", flush=True)
    img = cv2.imread(inp, cv2.IMREAD_UNCHANGED)
    if img is None:
        raise SystemExit(f"image illisible: {inp}")
    enhanced, _ = up.enhance(img, outscale=scale)
    cv2.imwrite(out, enhanced)
    print(f"upscale {img.shape[1]}x{img.shape[0]} -> {enhanced.shape[1]}x{enhanced.shape[0]}")


def main(inp, out, scale=4):
    outdir = os.path.dirname(os.path.abspath(out))
    if os.path.exists(SUPERSCALE_BIN):
        t0 = __import__("time").time()
        produced = upscale_superscale(inp, outdir, scale)
        if os.path.abspath(produced) != os.path.abspath(out):
            os.replace(produced, out)
        print(f"upscale superscale (Neural Engine): {time.time()-t0:.1f}s -> {out}")
        return
    print("superscale absent, repli torch…", flush=True)
    upscale_torch(inp, out, scale)


if __name__ == "__main__":
    import time
    inp = sys.argv[1]
    out = sys.argv[2]
    scale = int(sys.argv[3]) if len(sys.argv) > 3 else 4
    main(inp, out, scale)

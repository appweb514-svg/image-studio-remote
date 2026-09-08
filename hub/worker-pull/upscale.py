#!/usr/bin/env python3
"""Upscale Real-ESRGAN x4 (env realesrgan-env isolé, torch 2.2 épinglé)."""
import os
import sys

import cv2
from basicsr.archs.rrdbnet_arch import RRDBNet
from realesrgan import RealESRGANer

LOCAL_WEIGHTS = os.path.expanduser(
    "~/realesrgan-env/lib/python3.12/site-packages/weights/RealESRGAN_x4plus.pth")
REMOTE_WEIGHTS = ("https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/"
                  "RealESRGAN_x4plus.pth")


def pick_device():
    # GPU Apple (MPS) si dispo, sinon CPU. Variable d'env pour forcer.
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


def main(inp, out, scale=4, tile=256):
    model = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23,
                    num_grow_ch=32, scale=scale)
    device, half = pick_device()
    weights = LOCAL_WEIGHTS if os.path.exists(LOCAL_WEIGHTS) else REMOTE_WEIGHTS
    up = RealESRGANer(
        scale=scale,
        model_path=weights,
        model=model, tile=tile, tile_pad=10, pre_pad=0,
        half=half, device=device,
    )
    print(f"device: {device} (half={half})", flush=True)
    img = cv2.imread(inp, cv2.IMREAD_UNCHANGED)
    if img is None:
        raise SystemExit(f"image illisible: {inp}")
    enhanced, _ = up.enhance(img, outscale=scale)
    cv2.imwrite(out, enhanced)
    print(f"upscale {img.shape[1]}x{img.shape[0]} -> {enhanced.shape[1]}x{enhanced.shape[0]}")


if __name__ == "__main__":
    inp = sys.argv[1]
    out = sys.argv[2]
    scale = int(sys.argv[3]) if len(sys.argv) > 3 else 4
    main(inp, out, scale)

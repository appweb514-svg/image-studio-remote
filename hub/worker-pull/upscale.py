#!/usr/bin/env python3
"""Upscale Real-ESRGAN x4 (env realesrgan-env isolé, torch 2.2 épinglé)."""
import sys

import cv2
from basicsr.archs.rrdbnet_arch import RRDBNet
from realesrgan import RealESRGANer


def main(inp, out, scale=4, tile=256):
    model = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23,
                    num_grow_ch=32, scale=scale)
    up = RealESRGANer(
        scale=scale,
        model_path="https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth",
        model=model, tile=tile, tile_pad=10, pre_pad=0,
        half=False, device="cpu",
    )
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

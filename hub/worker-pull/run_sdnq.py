#!/usr/bin/env python3
"""Génération via Disty0 SDNQ (diffusers + torch, env sdnq-env isolé).
Usage: run_sdnq.py --prompt P --steps N --width W --height H --seed S --output O [--negative-prompt N]
Affiche 'STEP i/N' sur stdout pour le suivi de progression.
"""
import argparse
import time

import torch
import diffusers
from sdnq import SDNQConfig  # noqa: F401  (enregistre le schéma SDNQ)

REPO = ("/Users/gildas/.cache/huggingface/hub/models--Disty0--FLUX.2-klein-4B-"
        "SDNQ-4bit-dynamic/snapshots/45e9cc76cb70f84473ce5c6c2e2282d0ef3c6ecd")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prompt", required=True)
    ap.add_argument("--steps", type=int, default=4)
    ap.add_argument("--width", type=int, default=512)
    ap.add_argument("--height", type=int, default=512)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--output", required=True)
    ap.add_argument("--negative-prompt", default="")
    args = ap.parse_args()

    pipe = diffusers.Flux2KleinPipeline.from_pretrained(REPO, torch_dtype=torch.bfloat16)
    pipe.enable_model_cpu_offload()
    state = {"n": 0}

    def callback(pipe_obj, step, timestep, kwargs):
        state["n"] += 1
        print(f"STEP {state['n']}/{args.steps}", flush=True)
        return kwargs

    image = pipe(
        prompt=args.prompt,
        negative_prompt=args.negative_prompt or None,
        height=args.height, width=args.width,
        guidance_scale=1.0,
        num_inference_steps=args.steps,
        generator=torch.Generator().manual_seed(args.seed),
        callback_on_step_end=callback,
    ).images[0]
    image.save(args.output)
    print(f"DONE {args.output}", flush=True)


if __name__ == "__main__":
    t0 = time.time()
    main()
    print(f"total: {time.time()-t0:.0f}s", flush=True)

/**
 * Presentational darkroom backdrop: deep warm charcoal, a single faint
 * candle-warm halo, film grain + vignette (via body::before/::after).
 * No motion, no neon — matte paper feel.
 */
export function Aurora() {
  return (
    <div className="aurora" aria-hidden>
      <div className="aurora-blob aurora-blob-1" />
      <div className="aurora-blob aurora-blob-2" />
      <div className="aurora-blob aurora-blob-3" />
    </div>
  );
}

/**
 * Kept for API compatibility with the live "tirage" card.
 * Renders nothing visible — the safelight shimmer lives in CSS (.scanline).
 */
export function Particles() {
  return <div className="particles" aria-hidden />;
}

/** Studio monogram — thin serif "IS" in a hairline circle (CSS draws it). */
export function Monogram({ size = 44 }: { size?: number }) {
  return (
    <span className="monogram" style={{ width: size, height: size }} aria-hidden />
  );
}

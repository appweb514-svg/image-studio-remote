/**
 * Purely presentational backdrop: slow drifting aurora blobs over a
 * deep-space base, with a faint grid + noise overlay. CSS-only animation;
 * disabled under prefers-reduced-motion in styles.css.
 */
export function Aurora() {
  return (
    <div className="aurora" aria-hidden>
      <div className="aurora-blob aurora-blob-1" />
      <div className="aurora-blob aurora-blob-2" />
      <div className="aurora-blob aurora-blob-3" />
      <div className="aurora-grid" />
      <div className="aurora-stars" />
    </div>
  );
}

const PARTICLES = Array.from({ length: 12 }, (_, i) => i);

/**
 * CSS-only particle field (~12 dots) orbiting a frame while a job runs.
 * Staggered via inline animation-delay.
 */
export function Particles() {
  return (
    <div className="particles" aria-hidden>
      {PARTICLES.map((i) => (
        <i key={i} style={{ animationDelay: `${(i * 0.35).toFixed(2)}s` }} />
      ))}
    </div>
  );
}

/** App monogram — gradient prism mark. */
export function Monogram({ size = 44 }: { size?: number }) {
  return (
    <span className="monogram" style={{ width: size, height: size }} aria-hidden>
      <svg viewBox="0 0 32 32" fill="none">
        <defs>
          <linearGradient id="mono-g" x1="4" y1="4" x2="28" y2="28" gradientUnits="userSpaceOnUse">
            <stop stopColor="#7c3aed" />
            <stop offset="1" stopColor="#22d3ee" />
          </linearGradient>
        </defs>
        <path
          d="M16 3 29 10.5v11L16 29 3 21.5v-11L16 3Z"
          stroke="url(#mono-g)"
          strokeWidth="1.6"
          strokeLinejoin="round"
        />
        <path d="M16 3v26M3 10.5l13 7 13-7" stroke="url(#mono-g)" strokeWidth="1.1" opacity="0.55" />
        <circle cx="16" cy="17.5" r="3" fill="url(#mono-g)" />
      </svg>
    </span>
  );
}

export function ProgressBar({
  value,
  indeterminate = false,
  glow = false,
  showPercent = false,
}: {
  value: number;
  indeterminate?: boolean;
  glow?: boolean;
  showPercent?: boolean;
}) {
  const pct = Math.max(0, Math.min(100, Math.round(value)));
  return (
    <div className={`progress-wrap ${glow ? "progress-glow" : ""}`}>
      <div
        className={`progress ${glow ? "progress-glow-bar" : ""} ${indeterminate ? "progress-indeterminate" : ""}`}
        role="progressbar"
        aria-valuenow={indeterminate ? undefined : pct}
        aria-valuemin={0}
        aria-valuemax={100}
      >
        <div className="progress-fill" style={{ width: indeterminate ? "100%" : `${pct}%` }} />
      </div>
      {showPercent && (
        <span className="progress-percent tnum" aria-hidden>
          {pct}%
        </span>
      )}
    </div>
  );
}

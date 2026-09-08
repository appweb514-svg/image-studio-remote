export function ProgressBar({ value, indeterminate = false }: { value: number; indeterminate?: boolean }) {
  const pct = Math.max(0, Math.min(100, Math.round(value)));
  return (
    <div className={`progress ${indeterminate ? "progress-indeterminate" : ""}`} role="progressbar" aria-valuenow={indeterminate ? undefined : pct} aria-valuemin={0} aria-valuemax={100}>
      <div className="progress-fill" style={{ width: indeterminate ? "100%" : `${pct}%` }} />
    </div>
  );
}

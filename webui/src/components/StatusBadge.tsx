import type { JobStatus, UpscaleJobStatus } from "../types";

/** Stamped letterpress labels — uppercase, letterspaced. */
const LABELS: Record<JobStatus, string> = {
  pending: "En file",
  running: "En cours",
  completed: "Terminé",
  cancelled: "Annulé",
  failed: "Échec",
};

export function StatusBadge({ status }: { status: JobStatus }) {
  return (
    <span className={`badge badge-${status}`}>
      <span className="status-dot" aria-hidden />
      {LABELS[status] ?? status}
    </span>
  );
}

const UPSCALE_LABELS: Record<UpscaleJobStatus, string> = {
  queued: "En file",
  running: "En cours",
  completed: "Terminé",
  failed: "Échec",
};

export function UpscaleStatusBadge({ status }: { status: UpscaleJobStatus }) {
  return (
    <span className={`badge badge-up-${status}`}>
      <span className="status-dot" aria-hidden />
      {UPSCALE_LABELS[status] ?? status}
    </span>
  );
}

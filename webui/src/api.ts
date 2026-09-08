// Typed API client. All requests go to the same origin under /api/v1 and rely
// on the HttpOnly session cookie set by the server (no token storage here).

type UnauthorizedListener = () => void;
let onUnauthorized: UnauthorizedListener | null = null;

export function setUnauthorizedListener(fn: UnauthorizedListener | null) {
  onUnauthorized = fn;
}

export class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

const BASE = "/api/v1";

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(BASE + path, {
    credentials: "same-origin",
    headers:
      init?.body !== undefined ? { "Content-Type": "application/json" } : undefined,
    ...init,
  });
  if (res.status === 401) {
    onUnauthorized?.();
    throw new ApiError(401, "Non authentifié");
  }
  if (!res.ok) {
    let message = `Erreur ${res.status}`;
    try {
      const data = (await res.json()) as { error?: string };
      if (data?.error) message = data.error;
    } catch {
      // keep default message
    }
    throw new ApiError(res.status, message);
  }
  if (res.status === 204) return undefined as T;
  return (await res.json()) as T;
}

function get<T>(path: string): Promise<T> {
  return request<T>(path);
}
function post<T>(path: string, body?: unknown): Promise<T> {
  return request<T>(path, { method: "POST", body: JSON.stringify(body ?? {}) });
}
function patch<T>(path: string, body: unknown): Promise<T> {
  return request<T>(path, { method: "PATCH", body: JSON.stringify(body) });
}
function del<T>(path: string): Promise<T> {
  return request<T>(path, { method: "DELETE" });
}

export interface OkResponse {
  ok: true;
}

export const api = {
  login: (token: string) => post<OkResponse>("/auth/login", { token }),
  logout: () => post<OkResponse>("/auth/logout"),

  status: () => get<import("./types").SystemStatus>("/status"),
  capabilities: () => get<import("./types").Capabilities>("/capabilities"),
  models: () => get<import("./types").ModelRow[]>("/models"),
  presets: () => get<import("./types").Presets>("/presets"),

  queue: () => get<import("./types").JobDTO[]>("/queue"),
  job: (id: string) => get<import("./types").JobDTO>(`/jobs/${encodeURIComponent(id)}`),

  generate: (body: import("./types").GenerateRequest) => post<OkResponse>("/generate", body),
  cancelJob: (id: string) => post<OkResponse>(`/jobs/${encodeURIComponent(id)}/cancel`),
  retryJob: (id: string) => post<OkResponse>(`/jobs/${encodeURIComponent(id)}/retry`),
  duplicateJob: (id: string) => post<OkResponse>(`/jobs/${encodeURIComponent(id)}/duplicate`),
  deleteJob: (id: string) => del<OkResponse>(`/jobs/${encodeURIComponent(id)}`),
  reorder: (order: string[]) => patch<OkResponse>("/queue/reorder", { order }),

  history: () => get<import("./types").GalleryItemDTO[]>("/history"),
  setFlag: (id: string, flag: "pick" | "reject" | null) =>
    post<OkResponse>(`/gallery/${encodeURIComponent(id)}/flag`, { flag }),
  setRating: (id: string, rating: number) =>
    post<OkResponse>(`/gallery/${encodeURIComponent(id)}/rating`, { rating }),
  reuse: (id: string) => post<OkResponse>(`/gallery/${encodeURIComponent(id)}/reuse`),
  variation: (id: string) => post<OkResponse>(`/gallery/${encodeURIComponent(id)}/variation`),

  upload: (filename: string, mime: string, dataBase64: string) =>
    post<{ path: string }>("/uploads", { filename, mime, data_base64: dataBase64 }),

  upscaleModels: () => get<import("./types").UpscaleModel[]>("/upscale/models"),
  upscaleRecommendations: (params: {
    image_id?: string;
    model?: string;
    width?: number;
    height?: number;
  }) => {
    const qs = new URLSearchParams();
    if (params.image_id) qs.set("image_id", params.image_id);
    if (params.model) qs.set("model", params.model);
    if (params.width !== undefined) qs.set("width", String(params.width));
    if (params.height !== undefined) qs.set("height", String(params.height));
    return get<import("./types").UpscaleRecommendation[]>(
      `/upscale/recommendations?${qs.toString()}`,
    );
  },
  createUpscaleJob: (body: import("./types").UpscaleJobRequest) =>
    post<{ job_id: string }>("/upscale/jobs", body),
  upscaleJob: (id: string) =>
    get<import("./types").UpscaleJobDTO>(`/upscale/jobs/${encodeURIComponent(id)}`),
  upscaleJobs: () => get<import("./types").UpscaleJobDTO[]>("/upscale/jobs"),
};

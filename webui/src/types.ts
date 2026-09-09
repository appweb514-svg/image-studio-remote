// Shared types for the MLXBits Image Studio API (/api/v1).

export type JobStatus = "pending" | "running" | "completed" | "cancelled" | "failed";
export type Flag = "pick" | "reject";

export interface Family {
  id: string;
  display_name: string;
  web_enqueue: boolean;
  supports_edit: boolean;
  max_edit_images: number;
  supports_fast_mode?: boolean;
  supports_prompt_enhance?: boolean;
  fast_mode_note?: string;
  prompt_enhance_note?: string;
}

export interface ModelInfo {
  id: string;
  family: string;
  display_name: string;
  is_distilled: boolean;
  default_steps: number;
  default_guidance: number;
  supports_negative_prompt: boolean;
  recommended_quantize: number | null;
  approximate_size_gb: number;
}

export interface Capabilities {
  families: Family[];
  models: ModelInfo[];
  quantize_options: number[];
  batch_limits: { min: number; max: number };
  dimension_constraints: { min_edge: number; max_edge: number; multiple_of: number };
}

export interface ModelRow {
  id: string;
  display_name: string;
  family: string;
  on_disk_q8: boolean;
  on_disk_q4: boolean;
  size_gb_q8: number | null;
  size_gb_q4: number | null;
  repo_url?: string;
}

export interface JobDTO {
  id: string;
  family: string;
  status: JobStatus;
  status_message?: string;
  status_line?: string;
  step_timing?: unknown;
  prompt?: string;
  negative_prompt?: string;
  model?: string;
  seed?: number | null;
  seeds?: number[] | null;
  resolved_seed?: number | null;
  width?: number;
  height?: number;
  steps?: number;
  guidance?: number;
  quantize?: number;
  low_ram?: boolean;
  image_strength?: number;
  has_image_input: boolean;
  current_step: number;
  total_steps: number;
  progress: number;
  output_path?: string;
  output_paths: string[];
  board?: string;
  created_at: string;
  started_at?: string;
  completed_at?: string;
  preview_url: string;
}

export interface ImageMetadata {
  prompt?: string;
  negative_prompt?: string;
  model?: string;
  seed?: number;
  steps?: number;
  guidance?: number;
  width?: number;
  height?: number;
  quantize?: number;
  loras: string[];
  enhanced_prompt?: string;
  generation_seconds?: number;
}

export interface GalleryItemDTO {
  id: string;
  url: string;
  thumbnail_url: string;
  filename: string;
  board?: string;
  family: string;
  modified_at: string;
  flag?: Flag;
  rating: number;
  metadata?: ImageMetadata;
}

export interface SystemStatus {
  app: string;
  remoteAccess: {
    is_running: boolean;
    allow_lan: boolean;
    require_auth: boolean;
    connected_clients: number;
  };
  system: {
    chip: string;
    chip_generation?: string;
    memory: { total_gb: number; pressure_ratio?: number; swap_used_gb?: number };
    storage: { free_gb: number; total_gb: number };
    loaded_model?: string;
    loaded_model_memory_gb?: number;
    queue_length: number;
    versions: { app: string; mflux?: string; mac_os?: string };
  };
  queue: { pending: number; running_flux: number; running_krea2: number; running_zimage: number };
}

export interface Presets {
  templates: { id: string; name: string; positive: string; negative: string }[];
  model_defaults: {
    model: string;
    steps?: number;
    guidance?: number;
    width?: number;
    height?: number;
    quantize?: number;
    low_ram?: boolean;
  }[];
}

export interface GenerateRequest {
  family?: string;
  model?: string;
  custom_repo?: string;
  prompt: string;
  negative_prompt?: string;
  width?: number;
  height?: number;
  steps?: number;
  guidance?: number;
  seed?: number | null;
  batch?: number;
  quantize?: number;
  low_ram?: boolean;
  board?: string;
  image_path?: string;
  image_strength?: number;
  edit_mode?: boolean;
  edit_image_paths?: string[];
  loras?: { path: string; strength?: number; enabled?: boolean }[];
  fast_mode?: boolean;
  enhance_prompt?: boolean;
}

// Upscaling (Superscale / Real-ESRGAN)
export type UpscaleJobStatus = "queued" | "running" | "completed" | "failed";

export interface UpscaleModel {
  name: string;
  display_name: string;
  scale: number;
  tile_size: number;
  is_default: boolean;
  installed: boolean;
  downloading: boolean;
  short_description: string;
  detailed_description: string;
}

export interface UpscaleRecommendation {
  label: string;
  width: number;
  height: number;
  note: string;
  recommended: boolean;
}

export interface UpscaleJobRequest {
  image_id?: string;
  path?: string;
  model?: string;
  scale?: number;
  target_width?: number;
  target_height?: number;
  stretch?: boolean;
  face_enhance?: boolean;
}

export interface UpscaleJobDTO {
  id: string;
  status: UpscaleJobStatus;
  model: string;
  input_path: string;
  output_path?: string;
  phase?: string;
  tiles_done?: number;
  tiles_total?: number;
  error?: string;
  created_at: string;
}

// SSE payloads
export interface JobEventBase {
  job_id: string;
  family?: string;
}
export interface JobCreatedEvent extends JobEventBase {}
export interface JobStartedEvent extends JobEventBase {
  total_steps: number;
}
export interface JobProgressEvent extends JobEventBase {
  step: number;
  total_steps: number;
  status_line?: string;
  phase?: string;
}
export interface JobPreviewEvent extends JobEventBase {
  jpeg_base64: string;
}
export interface JobCompletedEvent extends JobEventBase {
  output_path?: string;
  seed?: number;
}
export interface JobFailedEvent extends JobEventBase {
  message: string;
}
export interface ModelLoadingEvent {
  label: string;
}
export interface ModelLoadedEvent extends ModelLoadingEvent {
  memory_gb?: number;
}
export interface DownloadProgressEvent {
  message: string;
}
export interface UpscaleQueuedEvent {
  job_id: string;
}
export interface UpscaleStartedEvent {
  job_id: string;
}
export interface UpscaleProgressEvent {
  job_id: string;
  phase?: string;
  tiles_done?: number;
  tiles_total?: number;
}
export interface UpscaleCompletedEvent {
  job_id: string;
  output_path?: string;
}
export interface UpscaleFailedEvent {
  job_id: string;
  message: string;
}

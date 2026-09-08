# Remote Access — API v1

L'app macOS embarque un serveur HTTP (aucune dépendance tierce) qui expose le
Web UI statique et une API versionnée. Deux modes :

- **Web UI embarquée** (LAN / fallback) : l'app sert elle-même le frontend
  React compilé (`Resources/webui_dist`).
- **Web UI externe** : un frontend hébergé ailleurs (reverse proxy, conteneur)
  consomme la même API. Configurer les origines autorisées via
  `defaults write com.mlxbits.image-studio remoteAccessAllowedOrigins -array "https://studio.exemple.fr"`.
  Toute autre origine reçoit une réponse sans en-têtes CORS.

## Activation

`Settings ▸ Remote Access` :

| Option | Défaut | Effet |
|---|---|---|
| Enable Remote Web UI | OFF | démarre/arrête le serveur |
| Port | 7860 | port TCP |
| Allow LAN | OFF | OFF = 127.0.0.1 uniquement |
| Require auth | ON | token + sessions |

Le token (32 octets aléatoires) est stocké dans le **trousseau macOS** ; il est
régénérable depuis l'UI (déconnecte toutes les sessions). Aucune exposition
Internet automatique : pour l'accès extérieur, utiliser **NetBird/Tailscale**
ou un reverse proxy HTTPS — jamais de port forwarding direct.

## Authentification

- Navigateur : `POST /api/v1/auth/login {"token": "..."}` → cookie de session
  `mlxbits_session` (HttpOnly, SameSite=Lax, TTL 12 h glissantes).
- Client API : en-tête `Authorization: Bearer <token>`.
- Rate limiting : 8 échecs de login / minute / IP → 429.
- Si `Require auth` est OFF (usage localhost uniquement), tout est ouvert.

## Endpoints

| Méthode | Chemin | Description |
|---|---|---|
| GET | `/api/v1/status` | dashboard (machine, mémoire, modèle chargé, file) |
| GET | `/api/v1/capabilities` | familles, modèles, contraintes (construit l'UI) |
| GET | `/api/v1/models` | modèles installés/disponibles, tailles Q8/Q4 |
| GET | `/api/v1/queue` | tous les jobs (toutes familles) |
| GET | `/api/v1/jobs/{id}` | un job |
| GET | `/api/v1/jobs/{id}/preview` | preview live (JPEG réduit) ou image finale (PNG) |
| POST | `/api/v1/jobs/{id}/cancel` | annule (pending) ou interrompt (running) |
| POST | `/api/v1/jobs/{id}/retry` | remet en file |
| POST | `/api/v1/jobs/{id}/duplicate` | duplique |
| DELETE | `/api/v1/jobs/{id}` | supprime le job (fichiers conservés) |
| PATCH | `/api/v1/queue/reorder` | `{"order": ["id", …]}` réordonne les jobs en attente |
| POST | `/api/v1/generate` | voir ci-dessous |
| GET | `/api/v1/history` | galerie (thumbnail, flags, métadonnées) |
| GET | `/api/v1/images/{id}[?thumbnail=1]` | image de la galerie |
| POST | `/api/v1/gallery/{id}/flag` | `{"flag": "pick"|"reject"|null}` (sync natif via xattrs) |
| POST | `/api/v1/gallery/{id}/rating` | `{"rating": 0-5}` |
| POST | `/api/v1/gallery/{id}/reuse` | régénère avec les mêmes réglages |
| POST | `/api/v1/gallery/{id}/variation` | régénère avec un nouveau seed |
| POST | `/api/v1/uploads` | upload img2img (JSON base64, magic bytes vérifiés) |
| GET | `/api/v1/presets` | templates de prompt + defaults par modèle |
| GET | `/api/v1/events` | flux SSE (voir ci-dessous) |
| POST | `/api/v1/auth/login` / `/logout` | session navigateur |
| GET | `/api/v1/generate` accepte aussi `edit_mode` + `edit_image_paths` | édition FLUX.2 (voir ci-dessous) |
| GET | `/api/v1/upscale/models` | modèles Superscale (Real-ESRGAN), état installé |
| POST | `/api/v1/upscale/models/{name}/download` | télécharge + vérifie (SHA-256) un modèle |
| GET | `/api/v1/upscale/recommendations` | résolutions recommandées (`?image_id=` ou `?width=&height=`, `?model=`) |
| POST | `/api/v1/upscale/jobs` | lance un upscale (voir ci-dessous) |
| GET | `/api/v1/upscale/jobs[/{id}]` | jobs d'upscaling |

### Édition (FLUX.2 Klein edit)

`POST /api/v1/generate` avec `"edit_mode": true` et `"edit_image_paths": [...]`
(1 à 4 chemins issus de `/uploads`) : changement d'angle, texture, couleur,
ajout de décor, fusion de deux images — le prompt décrit la transformation.
Backend : `mflux-generate-flux2-edit` (les champs `negative_prompt`,
`image_strength`, `batch` sont ignorés).

### Upscaling (Superscale, modèle résident)

Real-ESRGAN via CoreML + Neural Engine (dépendance SPM `SuperscaleKit`).
Le modèle chargé **reste en mémoire** entre les upscales (warm residency,
réglage `superscaleKeepWarm`, défaut ON) — les runs suivants sautent le chargement.

`POST /api/v1/upscale/jobs` : `{"image_id": "<uuid galerie>"}` ou
`{"path": "<uploads/output>"}`, plus au choix `"scale": 2.0` **ou**
`"target_width"/"target_height"` (+ `stretch`), `"model"`, `"face_enhance"`.
La sortie est écrite dans le board `Upscaled/` du dossier d'output — elle
apparaît dans la galerie native et Web. Événements SSE : `upscaleQueued`,
`upscaleStarted`, `upscaleProgress` {tiles_done, tiles_total, phase},
`upscaleCompleted`, `upscaleFailed`.

`GET /api/v1/upscale/recommendations` renvoie les résolutions conseillées :
scale natif du modèle (×2/×4, recommandé si ≤ 4K), palier ×2, Fit 2K/4K
(ratio préservé, arrondi multiple de 8), avec un flag `recommended`.

### POST /api/v1/generate

```json
{
  "family": "flux",                  // flux | krea2 | zimage
  "model": "flux2-klein-4b",         // id FluxModelVariant, ou custom_repo
  "custom_repo": null,
  "prompt": "…",                     // requis
  "negative_prompt": "",             // si supporté
  "width": 1024, "height": 1024,     // 64–4096, multiple de 8
  "steps": 4, "guidance": 1.0,
  "seed": null,                      // null = aléatoire
  "batch": 1,                        // 1–16, seeds auto
  "quantize": 8,                     // 0 = aucun
  "low_ram": false,
  "board": "Default",
  "image_path": null,                // chemin renvoyé par /uploads (img2img)
  "image_strength": 0.75,
  "loras": [{"path": "…", "strength": 1.0, "enabled": true}]
}
```

Réponses : `200 {"ok": true}`, `400 {"error": "…"}`.

### SSE `/api/v1/events`

Frames `event: <nom>` + `data: <json>`. Noms : `jobCreated`, `jobStarted`,
`jobProgress` {step, total_steps, status_line?}, `jobPreview` {jpeg_base64}
(préviews réduites ~512 px, JPEG q≈0.55 — l'original reste local),
`jobCompleted`, `jobFailed`, `jobCancelled`, `queueChanged`, `modelLoading`,
`modelLoaded`, `modelUnloaded`, `downloadProgress`.

## Architecture

```
HTTP (RemoteHTTPServer, NWListener)
  → RemoteAccessStore.route (auth, CORS, dispatch)
    → GenerationService / GalleryStore / AppSettings / TimingStore
      → JobRunner / MfluxDriverController (mflux)
```

La Web UI et SwiftUI partagent exactement les mêmes stores (`JobStore`,
`Krea2JobStore`, `ZImageJobStore`, `GalleryStore`, `ProgressMonitor` émet des
événements en lisant ces stores) : tout changement côté natif apparaît dans le
navigateur et inversement. Le mode natif ne dépend pas du serveur : Remote
Access OFF = zéro socket.

## Sécurité

- Bind loopback par défaut ; LAN nécessite un toggle explicite.
- Chemins de fichiers statiques : normalisation anti path-traversal.
- Uploads : extension dérivée du MIME déclaré, magic bytes vérifiés, 20 Mo max,
  stockage dans un dossier contrôlé (`RemoteAccessUploads/`), aucun chemin
  client accepté tel quel.
- Pas de commandes arbitraires : l'API ne fait qu'appeler les services Swift.
- CORS par liste blanche (défaut : same-origin only).
- Sessions révocables (regenerate token / logout / arrêt serveur).

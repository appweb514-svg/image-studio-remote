# MLXBits Image Studio — hub (Proxmox/Dokploy)
# Stage 1: build du frontend React (toujours a jour a chaque deploy).
# Stage 2: FastAPI + static + SQLite (/data).
FROM node:22-alpine AS ui
WORKDIR /ui
COPY webui/package*.json ./
RUN npm ci || npm install
COPY webui/ .
RUN npm run build

FROM python:3.12-slim
WORKDIR /app
COPY hub/hub-service/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY hub/hub-service/app ./app
COPY --from=ui /ui/dist /srv/webui

ENV STUDIO_DATA=/data
ENV WEBUI_DIST=/srv/webui
VOLUME /data
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]

# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

FROM node:24-bookworm-slim@sha256:3638d9a6fe4030bd716be989438248074489337ba3275657f93595428be4fc03 AS web-build
WORKDIR /build/app
COPY ports/tauri/app/package.json ports/tauri/app/package-lock.json ./
RUN npm ci
COPY ports/tauri/app/ ./
RUN npm run build:web

FROM rust:1-bookworm@sha256:14bc9c5966e7b3a385794b3d5389a8765668342025fbcc7b2e3d2866ac4bd8c3 AS engine-build
WORKDIR /build/engine
COPY app/ScanStudio/engine/ ./
RUN cargo build --locked --release --bin scanstudio-engine

FROM ghcr.io/astral-sh/uv:0.9.28@sha256:59240a65d6b57e6c507429b45f01b8f2c7c0bbeee0fb697c41a39c6a8e3a4cfb AS uv-bin

FROM python:3.13-slim-bookworm@sha256:67a1e1f215ccda113cfc024e8639049257e88f273898f595b61476d128d387e8 AS python-base

FROM python-base AS gateway-build
COPY --from=uv-bin /uv /usr/local/bin/uv
WORKDIR /opt/scanstudio/gateway
COPY ports/web/pyproject.toml ports/web/uv.lock ./
RUN uv lock --check \
    && uv sync --frozen --no-dev --no-install-project --compile-bytecode

FROM python-base AS runtime
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH=/opt/scanstudio/gateway/.venv/bin:$PATH \
    PYTHONPATH=/opt/scanstudio/gateway/src \
    SCANSTUDIO_ENGINE_PATH=/usr/local/bin/scanstudio-engine \
    SCANSTUDIO_WEB_STATIC_DIR=/opt/scanstudio/static \
    SCANSTUDIO_WEB_BIND=0.0.0.0 \
    SCANSTUDIO_WEB_PORT=8787

RUN useradd --system --uid 10001 --home-dir /nonexistent --shell /usr/sbin/nologin scanstudio

WORKDIR /opt/scanstudio/gateway
COPY --from=gateway-build /opt/scanstudio/gateway/.venv ./.venv
COPY ports/web/src/ ./src/

COPY --from=engine-build /build/engine/target/release/scanstudio-engine /usr/local/bin/scanstudio-engine
COPY --from=web-build /build/app/dist/ /opt/scanstudio/static/
COPY LICENSE THIRD_PARTY_NOTICES.md /opt/scanstudio/licenses/

USER 10001:10001
EXPOSE 8787
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8787/healthz', timeout=2).read()"]

ENTRYPOINT ["python", "-m", "scanstudio_web.cli"]

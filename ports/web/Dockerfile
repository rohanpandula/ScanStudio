# syntax=docker/dockerfile:1.7

FROM node:24-bookworm-slim AS web-build
WORKDIR /build/app
COPY ports/tauri/app/package.json ports/tauri/app/package-lock.json ./
RUN npm ci
COPY ports/tauri/app/ ./
RUN npm run build:web

FROM rust:1-bookworm AS engine-build
WORKDIR /build/engine
COPY app/ScanStudio/engine/ ./
RUN cargo build --locked --release --bin scanstudio-engine

FROM ghcr.io/astral-sh/uv:0.9.28 AS uv-bin

FROM python:3.13-slim-bookworm AS python-base

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

USER 10001:10001
EXPOSE 8787
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8787/healthz', timeout=2).read()"]

ENTRYPOINT ["python", "-m", "scanstudio_web.cli"]

# syntax=docker/dockerfile:1

ARG PYTHON_IMAGE=python:3.12-slim-bookworm@sha256:34386ef0cb081344d7ec1c103ba398e6e9f64e9ab3a1509accc92a4e24a07258

# ---- Build stage: install dependencies into an isolated virtualenv ----
FROM ${PYTHON_IMAGE} AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

RUN --mount=type=cache,target=/root/.cache/pip \
    --mount=type=bind,source=app/requirements.txt,target=/tmp/requirements.txt \
    --mount=type=bind,source=constraints.txt,target=/tmp/constraints.txt \
    pip install --require-virtualenv -r /tmp/requirements.txt -c /tmp/constraints.txt

# ---- Runtime stage: minimal image with only the venv and app code ----
FROM ${PYTHON_IMAGE} AS runtime

LABEL org.opencontainers.image.title="sample-app" \
      org.opencontainers.image.description="Minimal Flask greeting app served by gunicorn" \
      org.opencontainers.image.source="https://github.com/dxalpha01/greeting-container" \
      org.opencontainers.image.licenses="MIT"

# Gunicorn options live in the environment so they survive a Kubernetes `args` override.
# gunicorn binds to 0.0.0.0:$PORT and reads its worker count from $WEB_CONCURRENCY.
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080 \
    WEB_CONCURRENCY=2 \
    GUNICORN_CMD_ARGS="--worker-tmp-dir /dev/shm --access-logfile - --error-logfile -"

RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

WORKDIR /app

COPY --from=builder /opt/venv /opt/venv
COPY --chmod=u=rwX,go=rX app/ ./app/    

USER 10001:10001

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import os, urllib.request; urllib.request.urlopen(f'http://127.0.0.1:{os.environ.get(\"PORT\", \"8080\")}/healthz', timeout=2)"]

# The app package lives in /app/app, as in the original image.
CMD ["gunicorn", "--chdir", "app", "app:app"]

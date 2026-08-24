# --- build stage: install pinned dependencies into an isolated venv ----------
FROM python:3.12-slim AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build
COPY requirements.txt .
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install -r requirements.txt

# --- runtime stage: minimal image, non-root, no build tools -------------------
FROM python:3.12-slim

# Pull in Debian security updates published after the base image was cut
# (keeps OS packages ahead of fixed CVEs), then create a dedicated
# unprivileged user (uid > 10000 to avoid host uid collisions).
RUN apt-get update \
    && apt-get upgrade -y \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 app \
    && useradd --uid 10001 --gid app --shell /usr/sbin/nologin --create-home app

COPY --from=builder /opt/venv /opt/venv
WORKDIR /app
COPY src/ ./src/

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

USER 10001:10001
EXPOSE 8000

# Exec form: uvicorn is PID 1 and receives SIGTERM directly for clean shutdown.
CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8000"]

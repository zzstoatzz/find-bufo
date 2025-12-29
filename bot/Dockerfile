FROM python:3.11-slim

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

WORKDIR /app

COPY pyproject.toml .
COPY src/ src/

RUN uv sync --no-dev

CMD ["uv", "run", "bufo-bot"]

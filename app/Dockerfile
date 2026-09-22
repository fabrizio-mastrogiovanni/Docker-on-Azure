# Pinned base image. "latest" would drift silently.
FROM python:3.12-slim

# Don't write .pyc files; send logs straight out instead of buffering,
# so "docker logs" shows them immediately.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Copy requirements FIRST and install. Docker caches each step, so
# changing app.py later doesn't re-download every package.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# Run as a non-root user. Root inside a container is a real risk.
RUN useradd --create-home appuser
USER appuser

EXPOSE 8080
CMD ["python", "app.py"]

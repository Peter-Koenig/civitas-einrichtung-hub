# MapProxy-Image für das p2d2-AddOn (MapProxy 4.0.2 + Gunicorn 23.0.0 + Python 3.13).
# Abgeleitet aus p2d2-civitas-addon/tmp/mapproxy-build/Dockerfile (Standalone-Äquivalent).
# Build-Kontext: dieses Verzeichnis (Dockerfile + wsgi.py).
FROM python:3.13-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# MapProxy 4.0.2 (wie Standalone) + Gunicorn 23.0.0 (WSGI-Server)
RUN pip install --no-cache-dir \
    "MapProxy==4.0.2" \
    "gunicorn==23.0.0"

# WSGI-Einstieg: liest den Config-Pfad aus MAPROXY_CONFIG (Default /mapproxy/mapproxy.yaml).
COPY wsgi.py /app/wsgi.py
WORKDIR /app

# Nicht-root-User (Datei-Cache liegt auf dem PVC; fsGroup 1000 setzt die Rechte).
RUN useradd --create-home --uid 1000 mapproxy
USER mapproxy

EXPOSE 8080
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "3", "--threads", "4", "--timeout", "60", "wsgi:application"]

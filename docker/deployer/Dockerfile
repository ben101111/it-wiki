# Deploy-Dienst: baut das Wiki aus Gitea und veröffentlicht nur erfolgreiche Builds.
# Build-Kontext: /opt/it-wiki (wegen requirements.txt)
FROM python:3.12-slim

ARG DECAP_VERSION=3.16.3
ARG DECAP_SHA256=7c1efd6b616b4786e279aeef194dd21649a72058d3bc8d1f78901b574610dfb8

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

# Decap CMS einmalig beim Image-Build laden und prüfen – zur Laufzeit wird kein CDN benutzt.
RUN mkdir -p /opt/decap \
 && curl -fsSL "https://unpkg.com/decap-cms@${DECAP_VERSION}/dist/decap-cms.js" -o /opt/decap/decap-cms.js \
 && echo "${DECAP_SHA256}  /opt/decap/decap-cms.js" | sha256sum -c -

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

RUN useradd --uid 1001 --create-home --shell /usr/sbin/nologin deploy \
 && mkdir -p /srv/site/releases /srv/site/_status/logs /work \
 && chown -R deploy:deploy /srv/site /work
COPY docker/deployer/deploy.py /usr/local/bin/deploy.py
RUN chmod 0755 /usr/local/bin/deploy.py

USER deploy
WORKDIR /work
ENV PYTHONUNBUFFERED=1 NO_MKDOCS_2_WARNING=1
CMD ["/usr/local/bin/deploy.py"]

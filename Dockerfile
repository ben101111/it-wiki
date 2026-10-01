# Notfall-/Einzelbetrieb OHNE Gitea und Deploy-Dienst:
#   docker build -t it-wiki-standalone . && docker run -d -p 8080:80 -e AUTH_BASIC=off it-wiki-standalone
# Im Normalbetrieb baut der Deploy-Dienst (docker/deployer) das Wiki aus Gitea.

# ---------- Stufe 1: Website bauen ----------
FROM python:3.12-slim AS build
WORKDIR /wiki
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY mkdocs.yml .
COPY overrides ./overrides
COPY hooks ./hooks
COPY docs ./docs
RUN mkdocs build --strict --site-dir /site

# ---------- Stufe 2: Ausliefern mit nginx ----------
FROM nginx:stable-alpine
COPY docker/default.conf.template /etc/nginx/templates/default.conf.template
COPY --from=build /site /srv/site/current
RUN mkdir -p /srv/site/_status /etc/nginx/auth && touch /etc/nginx/auth/.htpasswd
ENV AUTH_BASIC="off"
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s CMD wget -q -O /dev/null http://127.0.0.1/healthz || exit 1

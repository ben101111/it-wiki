#!/usr/bin/env bash
# =============================================================================
#  Einrichtung Browser-Redaktion für die IT-Wissensdatenbank
#  (Gitea + Decap CMS + Deploy-Dienst)  –  Debian, Docker Compose
#
#  NEUE VM (Repository nach /opt/it-wiki geklont oder Paket dorthin entpackt):
#    sudo bash scripts/cms-install.sh docker           Docker CE + Compose-Plugin installieren (falls nötig)
#    sudo bash scripts/cms-install.sh install          alles in einem Durchlauf (fragt IP oder Domains ab)
#      ohne Rückfragen zu den Adressen:
#      sudo WIKI_URL=https://wiki.firma.de GITEA_URL=https://git.firma.de BEISPIELE=nein bash scripts/cms-install.sh install
#
#  ADRESSEN später ändern (IP <-> Domains):
#    sudo bash scripts/cms-install.sh adressen
#
#  BEISPIELBEITRÄGE der Vorlage entfernen:
#    sudo bash scripts/cms-install.sh beispiele
#
#  ALLES ENTFERNEN (vorher automatisches Backup, Bestätigung mit ENTFERNEN):
#    sudo bash /opt/it-wiki/scripts/cms-install.sh uninstall
#
#  UPDATE einer laufenden Installation (neues Paket z. B. nach ~/it-wiki-neu entpackt):
#    sudo bash ~/it-wiki-neu/it-wiki/scripts/cms-install.sh update
#
#  Einzelschritte:
#    sudo bash scripts/cms-install.sh check            Bestand prüfen (ändert nichts)
#    sudo bash scripts/cms-install.sh backup           Vollbackup nach /opt/backups
#    sudo bash scripts/cms-install.sh gitea            Gitea installieren + Admin anlegen
#    sudo bash scripts/cms-install.sh bootstrap        Organisation, Repo, Team, Deploy-Benutzer, OAuth-App
#    sudo bash scripts/cms-install.sh import           Bestehendes Wiki als Git-Repo nach Gitea pushen
#    sudo bash scripts/cms-install.sh apply            CMS-Dateien einspielen, testen, committen, pushen
#    sudo bash scripts/cms-install.sh deploy           Deploy-Dienst starten und Wiki umstellen
#    sudo bash scripts/cms-install.sh editor NAME MAIL Redakteur anlegen
#    sudo bash scripts/cms-install.sh status           Status anzeigen
#    sudo bash scripts/cms-install.sh test             automatische Abnahmetests (lesend)
#    sudo bash scripts/cms-install.sh test-fehler      Test 10: defekter Link blockiert Veröffentlichung
#
#  Jeder Schritt ist wiederholbar. Vor jeder Änderung prüft das Skript, dass ein
#  Backup von heute existiert. Es wird nichts gelöscht.
# =============================================================================
set -euo pipefail

WIKI_DIR="${WIKI_DIR:-/opt/it-wiki}"
GITEA_DIR="${GITEA_DIR:-/opt/gitea}"
BACKUP_DIR="${BACKUP_DIR:-/opt/backups}"
ORG="${ORG:-it-team}"
REPO="${REPO:-it-wiki}"
TEAM="${TEAM:-Redaktion}"
DEPLOY_USER="${DEPLOY_USER:-wiki-deploy}"
GITEA_IMAGE="gitea/gitea:1.27.3-rootless"
PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TS="$(date +%F-%H%M%S)"

c_ok()   { printf '\033[32m[OK]\033[0m %s\n' "$*"; }
c_info() { printf '\033[36m[..]\033[0m %s\n' "$*"; }
c_warn() { printf '\033[33m[!!]\033[0m %s\n' "$*"; }
die()    { printf '\033[31m[FEHLER]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "Bitte mit sudo ausführen."; }
need_cmd()  { command -v "$1" >/dev/null 2>&1 || die "Programm '$1' fehlt. Installieren: sudo apt install -y $2"; }

server_ip() {
  if [ -n "${SERVER_IP:-}" ]; then echo "$SERVER_IP"; return; fi
  hostname -I | awk '{print $1}'
}

norm_url() { # "wiki.firma.de" -> "https://wiki.firma.de", ohne / am Ende
  local u="${1%/}"; u="${u// /}"
  [ -z "$u" ] && return 0
  case "$u" in http://*|https://*) ;; *) u="https://$u" ;; esac
  echo "$u"
}

ask_urls() { # setzt WIKI_URL und GITEA_URL (Vorgabe per Umgebungsvariable möglich)
  local ip="$1" a
  if [ -n "${WIKI_URL:-}" ] && [ -n "${GITEA_URL:-}" ]; then
    WIKI_URL="$(norm_url "$WIKI_URL")"; GITEA_URL="$(norm_url "$GITEA_URL")"
  else
    echo
    echo "Wie sollen Wiki und Gitea erreichbar sein?"
    echo "  1) über die IP-Adresse:  http://$ip:8080 (Wiki)  und  http://$ip:3000 (Gitea)"
    echo "  2) über eigene Domains hinter einem Reverse Proxy mit HTTPS (z. B. Nginx Proxy Manager)"
    read -rp "Auswahl [1/2]: " a
    if [ "$a" = "2" ]; then
      read -rp "Domain für das Wiki  (z. B. wiki.firma.de): " WIKI_URL
      read -rp "Domain für Gitea     (z. B. git.firma.de):  " GITEA_URL
      WIKI_URL="$(norm_url "$WIKI_URL")"; GITEA_URL="$(norm_url "$GITEA_URL")"
      [ -n "$WIKI_URL" ] && [ -n "$GITEA_URL" ] || die "Beide Domains werden benötigt."
      [ "$WIKI_URL" != "$GITEA_URL" ] || die "Wiki und Gitea brauchen zwei verschiedene Domains."
    else
      WIKI_URL="http://$ip:8080"; GITEA_URL="http://$ip:3000"
    fi
  fi
  [[ "$WIKI_URL" =~ ^https?://[A-Za-z0-9.:-]+$ ]] || die "Ungültige Wiki-Adresse: $WIKI_URL (nur Schema + Host[:Port], kein Pfad)"
  [[ "$GITEA_URL" =~ ^https?://[A-Za-z0-9.:-]+$ ]] || die "Ungültige Gitea-Adresse: $GITEA_URL (nur Schema + Host[:Port], kein Pfad)"
  if [[ "$WIKI_URL" == https://* ]] && [[ "$GITEA_URL" == http://* ]]; then
    die "Wiki über HTTPS, Gitea über HTTP funktioniert nicht (der Browser blockiert die Anmeldung). Bitte beide über HTTPS."
  fi
  export WIKI_URL GITEA_URL
}

require_backup() {
  local latest
  latest="$(ls -1t "$BACKUP_DIR"/it-wiki-*.tar.gz 2>/dev/null | head -1 || true)"
  [ -n "$latest" ] || die "Kein Backup gefunden. Zuerst: sudo bash scripts/cms-install.sh backup"
  if [ "$(find "$latest" -mmin -720 | wc -l)" -eq 0 ]; then
    die "Letztes Backup ist älter als 12 Stunden ($latest). Bitte neu sichern: sudo bash scripts/cms-install.sh backup"
  fi
  c_ok "Backup vorhanden: $latest"
}

env_get() { # Datei Schlüssel
  [ -f "$1" ] && grep -E "^$2=" "$1" | tail -1 | cut -d= -f2- || true
}
env_set() { # Datei Schlüssel Wert   (ohne Wert im Terminal auszugeben)
  local f="$1" k="$2" v="$3"
  touch "$f"; chmod 600 "$f"
  if grep -qE "^$k=" "$f"; then
    local tmp; tmp="$(mktemp)"
    awk -v k="$k" -v v="$v" 'BEGIN{FS=OFS="="} $1==k {print k"="v; next} {print}' "$f" > "$tmp" && cat "$tmp" > "$f" && rm -f "$tmp"
  else
    printf '%s=%s\n' "$k" "$v" >> "$f"
  fi
}

gitea_url_local() { echo "http://127.0.0.1:3000"; }

netrc() { printf 'machine 127.0.0.1 login %s password %s\n' "$1" "$2"; }  # Zugangsdaten nicht in der Prozessliste

api() { # METHODE PFAD [JSON]  – nutzt $API_USER/$API_PASS
  local m="$1" p="$2" d="${3:-}"
  if [ -n "$d" ]; then
    curl -sS --netrc-file <(netrc "$API_USER" "$API_PASS") -X "$m" -H 'Content-Type: application/json' -d "$d" -w '\n%{http_code}' "$(gitea_url_local)/api/v1$p"
  else
    curl -sS --netrc-file <(netrc "$API_USER" "$API_PASS") -X "$m" -w '\n%{http_code}' "$(gitea_url_local)/api/v1$p"
  fi
}
api_code() { tail -1 <<<"$1"; }
api_body() { sed '$d' <<<"$1"; }

ask_admin() {
  if [ -z "${API_USER:-}" ]; then read -rp "Gitea-Admin-Benutzername: " API_USER; fi
  if [ -z "${API_PASS:-}" ]; then read -rsp "Passwort für $API_USER: " API_PASS; echo; fi
  local r; r="$(api GET /user)"
  [ "$(api_code "$r")" = "200" ] || die "Anmeldung an Gitea fehlgeschlagen (HTTP $(api_code "$r"))."
}

# ----------------------------------------------------------------------------- check
cmd_check() {
  echo "== Projektordner $WIKI_DIR"
  [ -d "$WIKI_DIR" ] || die "$WIKI_DIR nicht gefunden"
  for f in docker-compose.yml Dockerfile mkdocs.yml docker/default.conf.template requirements.txt .env .git; do
    if [ -e "$WIKI_DIR/$f" ]; then c_ok "$f vorhanden"; else c_warn "$f fehlt"; fi
  done
  echo "   Markdown-Seiten in docs/: $(find "$WIKI_DIR/docs" -name '*.md' | wc -l)"
  echo "   Bilder/Anhänge in docs/assets: $(find "$WIKI_DIR/docs/assets" -type f | wc -l)"
  if grep -q '^nav:' "$WIKI_DIR/mkdocs.yml"; then echo "   Navigation: feste nav: in mkdocs.yml ($(grep -c '\.md' "$WIKI_DIR/mkdocs.yml") Einträge)"; else echo "   Navigation: automatisch"; fi
  grep -q '^hooks:' "$WIKI_DIR/mkdocs.yml" && echo "   hooks: bereits vorhanden" || true
  echo; echo "== Docker"
  need_cmd docker docker-ce
  docker --version; docker compose version
  docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
  echo; echo "== Compose-Konfiguration (Auszug)"
  (cd "$WIKI_DIR" && docker compose config 2>/dev/null | sed -n '1,60p') || c_warn "docker compose config fehlgeschlagen"
  echo; echo "== Belegte Ports"
  ss -ltnp 2>/dev/null | awk 'NR==1 || /:(80|443|3000|8080|8443)\s/'
  if ss -ltn | grep ':3000 ' >/dev/null; then c_warn "Port 3000 ist belegt – Gitea braucht einen anderen Port"; else c_ok "Port 3000 frei"; fi
  echo; echo "== Wiki-Antwort"
  curl -s -o /dev/null -w "   http://127.0.0.1:8080/ -> HTTP %{http_code}\n" http://127.0.0.1:8080/ || true
  echo; echo "Server-IP (erkannt): $(server_ip)"
}

# ----------------------------------------------------------------------------- backup
cmd_backup() {
  need_root
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
  local meta="$BACKUP_DIR/docker-meta-$TS"
  mkdir -p "$meta"
  docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' > "$meta/docker-ps.txt" || true
  docker inspect it-wiki > "$meta/inspect-it-wiki.json" 2>/dev/null || true
  (cd "$WIKI_DIR" && docker compose config > "$meta/compose-it-wiki.resolved.yml" 2>/dev/null) || true
  [ -d "$GITEA_DIR" ] && (cd "$GITEA_DIR" && docker compose config > "$meta/compose-gitea.resolved.yml" 2>/dev/null) || true
  docker volume ls > "$meta/volumes.txt" || true
  local out="$BACKUP_DIR/it-wiki-$TS.tar.gz"
  local paths=("$WIKI_DIR" "$meta")
  if [ -d "$GITEA_DIR" ]; then
    c_info "Gitea wird für ein konsistentes Backup kurz angehalten"
    (cd "$GITEA_DIR" && docker compose stop gitea) || true
    paths+=("$GITEA_DIR")
  fi
  c_info "Erstelle $out"
  tar -czf "$out" "${paths[@]}" || die "tar meldet einen Fehler – Backup unvollständig"
  [ -d "$GITEA_DIR" ] && (cd "$GITEA_DIR" && docker compose start gitea) >/dev/null || true
  rm -rf "$meta"
  gzip -t "$out" || die "Backup-Archiv beschädigt"
  tar -tzf "$out" > "$out.list"
  grep -F "${WIKI_DIR#/}/mkdocs.yml" "$out.list" >/dev/null || die "mkdocs.yml fehlt im Backup"
  local n; n="$(wc -l < "$out.list")"; rm -f "$out.list"
  sha256sum "$out" > "$out.sha256"
  chmod 600 "$out" "$out.sha256"
  c_ok "Backup geprüft: $out ($(du -h "$out" | cut -f1), $n Einträge)"
}

# ----------------------------------------------------------------------------- gitea
cmd_gitea() {
  need_root; require_backup; need_cmd curl curl
  local ip; ip="$(server_ip)"
  [ -n "$ip" ] || die "Server-IP nicht erkannt – Aufruf mit SERVER_IP=1.2.3.4 sudo -E bash ..."
  if ss -ltn | grep ':3000 ' >/dev/null && ! docker ps --format '{{.Names}}' | grep -x gitea >/dev/null; then die "Port 3000 ist bereits belegt."; fi
  mkdir -p "$GITEA_DIR/data" "$GITEA_DIR/config"
  [ -f "$GITEA_DIR/docker-compose.yml" ] && cp -a "$GITEA_DIR/docker-compose.yml" "$GITEA_DIR/docker-compose.yml.bak-$TS"
  cp "$PKG_DIR/gitea/docker-compose.yml" "$GITEA_DIR/docker-compose.yml"
  local envf="$GITEA_DIR/.env"
  if [ -n "${GITEA_URL:-}" ]; then env_set "$envf" GITEA_URL "$GITEA_URL"; fi
  if [ -n "${WIKI_URL:-}" ]; then env_set "$envf" WIKI_URL "$WIKI_URL"; fi
  [ -n "$(env_get "$envf" GITEA_URL)" ] || env_set "$envf" GITEA_URL "http://$ip:3000"
  [ -n "$(env_get "$envf" WIKI_URL)" ]  || env_set "$envf" WIKI_URL  "http://$ip:8080"
  c_info "Lade Gitea-Image $GITEA_IMAGE"
  docker pull -q "$GITEA_IMAGE" >/dev/null
  for k in SECRET_KEY INTERNAL_TOKEN; do
    [ -n "$(env_get "$envf" "GITEA__security__$k")" ] || env_set "$envf" "GITEA__security__$k" "$(docker run --rm "$GITEA_IMAGE" gitea generate secret "$k")"
  done
  [ -n "$(env_get "$envf" GITEA__oauth2__JWT_SECRET)" ] || env_set "$envf" GITEA__oauth2__JWT_SECRET "$(docker run --rm "$GITEA_IMAGE" gitea generate secret JWT_SECRET)"
  chmod 600 "$envf"
  chown -R 1000:1000 "$GITEA_DIR/data" "$GITEA_DIR/config"
  (cd "$GITEA_DIR" && docker compose up -d)
  c_info "Warte auf Gitea ..."
  for _ in $(seq 1 60); do curl -fsS http://127.0.0.1:3000/api/healthz >/dev/null 2>&1 && break; sleep 2; done
  curl -fsS http://127.0.0.1:3000/api/healthz >/dev/null || die "Gitea antwortet nicht. Logs: cd $GITEA_DIR && docker compose logs"
  c_ok "Gitea läuft: http://$ip:3000"
  if [ -n "$(docker exec gitea gitea admin user list --admin 2>/dev/null | awk 'NR>1')" ]; then
    c_ok "Ein Gitea-Admin existiert bereits."
  else
    echo; echo "Ersten Gitea-Administrator anlegen (persönliches Konto, nicht 'admin'):"
    local u m p1 p2
    read -rp "  Benutzername: " u
    read -rp "  E-Mail: " m
    read -rsp "  Passwort (min. 12 Zeichen, Groß-/Kleinbuchstaben, Ziffer): " p1; echo
    read -rsp "  Passwort wiederholen: " p2; echo
    [ "$p1" = "$p2" ] || die "Passwörter stimmen nicht überein"
    docker exec gitea gitea admin user create --admin --username "$u" --email "$m" --password "$p1" --must-change-password=false >/dev/null
    c_ok "Admin '$u' angelegt. Anmeldung: http://$ip:3000/user/login"
    API_USER="$u"; API_PASS="$p1"   # für die folgenden Schritte im selben Durchlauf
  fi
}

# ----------------------------------------------------------------------------- bootstrap
cmd_bootstrap() {
  need_root; need_cmd jq jq; ask_admin
  local ip wiki_url gitea_url r
  ip="$(server_ip)"
  gitea_url="$(env_get "$GITEA_DIR/.env" GITEA_URL)"; gitea_url="${gitea_url:-http://$ip:3000}"
  wiki_url="$(env_get "$GITEA_DIR/.env" WIKI_URL)"; wiki_url="${wiki_url:-http://$ip:8080}"

  r="$(api GET "/orgs/$ORG")"
  if [ "$(api_code "$r")" != "200" ]; then
    r="$(api POST /orgs "{\"username\":\"$ORG\",\"full_name\":\"IT-Team\",\"visibility\":\"private\",\"repo_admin_change_team_access\":false}")"
    [ "$(api_code "$r")" = "201" ] || die "Organisation anlegen fehlgeschlagen: $(api_body "$r")"
    c_ok "Organisation $ORG angelegt"
  else c_ok "Organisation $ORG vorhanden"; fi

  r="$(api GET "/repos/$ORG/$REPO")"
  if [ "$(api_code "$r")" != "200" ]; then
    r="$(api POST "/orgs/$ORG/repos" "{\"name\":\"$REPO\",\"description\":\"IT-Wissensdatenbank (MkDocs)\",\"private\":true,\"default_branch\":\"main\",\"auto_init\":false}")"
    [ "$(api_code "$r")" = "201" ] || die "Repository anlegen fehlgeschlagen: $(api_body "$r")"
    c_ok "Privates Repository $ORG/$REPO angelegt"
  else c_ok "Repository $ORG/$REPO vorhanden"; fi

  local team_id
  team_id="$(api_body "$(api GET "/orgs/$ORG/teams/search?q=$TEAM")" | jq -r --arg t "$TEAM" '.data[]? | select(.name==$t) | .id' | head -1)"
  if [ -z "$team_id" ]; then
    r="$(api POST "/orgs/$ORG/teams" "{\"name\":\"$TEAM\",\"description\":\"Darf Wiki-Inhalte im Browser bearbeiten\",\"permission\":\"write\",\"includes_all_repositories\":false,\"can_create_org_repo\":false,\"units\":[\"repo.code\",\"repo.issues\",\"repo.pulls\"],\"units_map\":{\"repo.code\":\"write\",\"repo.issues\":\"write\",\"repo.pulls\":\"write\"}}")"
    [ "$(api_code "$r")" = "201" ] || die "Team anlegen fehlgeschlagen: $(api_body "$r")"
    team_id="$(api_body "$r" | jq -r .id)"
    c_ok "Team $TEAM (Schreiben) angelegt"
  else c_ok "Team $TEAM vorhanden"; fi
  r="$(api PUT "/teams/$team_id/repos/$ORG/$REPO")"
  case "$(api_code "$r")" in 204|200) c_ok "Team $TEAM hat Zugriff auf $ORG/$REPO";; *) die "Team-Zugriff fehlgeschlagen: $(api_body "$r")";; esac

  # Deploy-Benutzer (nur lesen)
  local envf="$WIKI_DIR/.env" deploy_pw token
  [ -f "$envf" ] || { cp "$PKG_DIR/.env.example" "$envf"; chmod 600 "$envf"; }
  r="$(api GET "/users/$DEPLOY_USER")"
  if [ "$(api_code "$r")" != "200" ]; then
    deploy_pw="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 28)Aa1"
    r="$(api POST /admin/users "{\"username\":\"$DEPLOY_USER\",\"email\":\"$DEPLOY_USER@noreply.invalid\",\"password\":\"$deploy_pw\",\"must_change_password\":false,\"visibility\":\"private\",\"full_name\":\"Wiki Deploy-Dienst\"}")"
    [ "$(api_code "$r")" = "201" ] || die "Deploy-Benutzer anlegen fehlgeschlagen: $(api_body "$r")"
    c_ok "Technischer Benutzer $DEPLOY_USER angelegt"
  fi
  r="$(api PUT "/repos/$ORG/$REPO/collaborators/$DEPLOY_USER" '{"permission":"read"}')"
  case "$(api_code "$r")" in 204|200) c_ok "$DEPLOY_USER: Lesezugriff auf $ORG/$REPO";; *) die "Lesezugriff setzen fehlgeschlagen: $(api_body "$r")";; esac
  if [ -z "$(env_get "$envf" GITEA_DEPLOY_TOKEN)" ] || [ "$(env_get "$envf" GITEA_DEPLOY_TOKEN)" = "TOKEN-AUS-GITEA" ]; then
    [ -n "${deploy_pw:-}" ] || { deploy_pw="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 28)Aa1"; \
      api PATCH "/admin/users/$DEPLOY_USER" "{\"login_name\":\"$DEPLOY_USER\",\"source_id\":0,\"password\":\"$deploy_pw\",\"must_change_password\":false}" >/dev/null; }
    token="$(curl -sS --netrc-file <(netrc "$DEPLOY_USER" "$deploy_pw") -X POST -H 'Content-Type: application/json' \
      -d "{\"name\":\"deployer-$TS\",\"scopes\":[\"read:repository\"]}" "$(gitea_url_local)/api/v1/users/$DEPLOY_USER/tokens" | jq -r '.sha1 // empty')"
    [ -n "$token" ] || die "Token für $DEPLOY_USER konnte nicht erstellt werden"
    env_set "$envf" GITEA_DEPLOY_USER "$DEPLOY_USER"
    env_set "$envf" GITEA_DEPLOY_TOKEN "$token"
    c_ok "Lese-Token für den Deploy-Dienst in $envf gespeichert"
  fi

  # OAuth-Anwendung für Decap CMS (öffentlicher Client, PKCE, kein Secret)
  local cid
  cid="$(env_get "$envf" OAUTH_CLIENT_ID)"
  if [ -z "$cid" ] || [ "$cid" = "CLIENT-ID-AUS-GITEA" ]; then
    r="$(api POST /user/applications/oauth2 "{\"name\":\"Decap CMS (IT-Wiki)\",\"redirect_uris\":[\"$wiki_url/admin/\"],\"confidential_client\":false}")"
    [ "$(api_code "$r")" = "201" ] || die "OAuth-Anwendung anlegen fehlgeschlagen: $(api_body "$r")"
    cid="$(api_body "$r" | jq -r .client_id)"
    env_set "$envf" OAUTH_CLIENT_ID "$cid"
    c_ok "OAuth-Anwendung „Decap CMS (IT-Wiki)“ angelegt (Redirect: $wiki_url/admin/)"
  else c_ok "OAuth-Client-ID bereits in .env"; fi

  env_set "$envf" WIKI_URL "$wiki_url"
  env_set "$envf" GITEA_URL "$gitea_url"
  env_set "$envf" GITEA_REPO "$ORG/$REPO"
  env_set "$envf" GITEA_BRANCH "main"
  [ -n "$(env_get "$envf" AUTH_BASIC)" ] || env_set "$envf" AUTH_BASIC "off"
  if [[ "$wiki_url" == https://* ]]; then env_set "$envf" DECAP_HTTP_LOGIN false; else env_set "$envf" DECAP_HTTP_LOGIN true; fi
  chmod 600 "$envf"
  c_ok "Werte in $envf eingetragen (Rechte 600)"
}

# ----------------------------------------------------------------------------- import
git_push() { # nutzt Admin-Zugang nur für diesen Befehl (nicht gespeichert)
  local cred; cred="$(printf '%s:%s' "$API_USER" "$API_PASS" | base64 -w0)"
  git -C "$WIKI_DIR" -c "http.extraHeader=Authorization: Basic $cred" push "$@"
}

cmd_import() {
  need_root; require_backup; need_cmd git git; need_cmd jq jq; ask_admin
  cd "$WIKI_DIR"
  git config --global --add safe.directory "$WIKI_DIR" 2>/dev/null || true
  # .gitignore ergänzen
  touch .gitignore
  for line in ".venv/" "site/" "__pycache__/" "*.pyc" "*.log" "*.tmp" "*.swp" "*~" ".DS_Store" "Thumbs.db" \
              ".env" ".env.*" "!.env.example" "docker/auth/" "*.htpasswd" ".htpasswd" "secrets/" "*.key" "*.pem" "*.pfx" \
              "link-pruefung/" "migration-output/" "migration-protokoll-*" "*.bak-*" "backups/"; do
    grep -qxF -- "$line" .gitignore || echo "$line" >> .gitignore
  done
  if [ ! -d .git ]; then
    git init -q -b main
    c_ok "Git-Repository initialisiert"
  fi
  git config user.name  >/dev/null || git config user.name "IT-Team"
  git config user.email >/dev/null || git config user.email "it-team@noreply.invalid"
  # Sicherheitsprüfung: keine Geheimnisse committen
  local secrets; secrets="$(git add -A --dry-run | grep -Ei "(\.env'?$|htpasswd|\.pem'?$|\.key'?$|\.pfx'?$|id_rsa)" || true)"
  if [ -n "$secrets" ]; then
    echo "$secrets"
    die "Diese Dateien würden committet – bitte .gitignore prüfen."
  fi
  git add -A
  if git rev-parse --verify -q HEAD >/dev/null; then
    git diff --cached --quiet || git commit -q -m "Stand vor CMS-Erweiterung"
  else
    git commit -q -m "Initial import of existing MkDocs IT knowledge base"
    c_ok "Erster Commit erstellt"
  fi
  local want="$(gitea_url_local)/$ORG/$REPO.git" have
  have="$(git remote get-url origin 2>/dev/null || true)"
  if [ -n "$have" ] && [ "$have" != "$want" ]; then
    # z. B. von GitHub geklont: Quelle als "upstream" behalten, Inhalte gehen ausschließlich ins lokale Gitea
    git remote get-url upstream >/dev/null 2>&1 && git remote remove origin || git remote rename origin upstream
    c_ok "Bisheriges Remote 'origin' ($have) in 'upstream' umbenannt – gepusht wird nur ins lokale Gitea"
    have=""
  fi
  [ -n "$have" ] || git remote add origin "$want"
  git checkout -q -B main
  git_push -q origin main
  local n_local n_remote
  n_local="$(git ls-files | wc -l)"
  n_remote="$(api_body "$(api GET "/repos/$ORG/$REPO/git/trees/main?recursive=true&per_page=10000")" | jq '[.tree[] | select(.type=="blob")] | length')"
  [ "$n_local" = "$n_remote" ] || die "Dateianzahl weicht ab: lokal $n_local, Gitea $n_remote"
  c_ok "Gepusht: $n_local Dateien in $ORG/$REPO (Branch main) – identisch mit lokalem Stand"
}

# ----------------------------------------------------------------------------- apply
cmd_apply() {
  need_root
  if [ "$(cd "$PKG_DIR" && pwd -P)" = "$(cd "$WIKI_DIR" 2>/dev/null && pwd -P)" ]; then
    c_ok "CMS-Dateien sind bereits enthalten – 'apply' ist nicht nötig."; return 0
  fi
  require_backup; need_cmd git git; ask_admin
  cd "$WIKI_DIR"
  [ -d .git ] || die "Zuerst: sudo bash scripts/cms-install.sh import"
  git diff --quiet && git diff --cached --quiet || die "Es gibt nicht committete Änderungen in $WIKI_DIR – bitte zuerst committen."
  git -c "http.extraHeader=Authorization: Basic $(printf '%s:%s' "$API_USER" "$API_PASS" | base64 -w0)" pull -q --ff-only origin main || die "git pull fehlgeschlagen"

  echo "Folgende Dateien werden angelegt bzw. geändert:"
  echo "  neu:      admin/index.html, admin/config.yml, admin/preview.css"
  echo "  neu:      hooks/wiki_cms.py, docker/deployer/Dockerfile, docker/deployer/deploy.py, .env.example"
  echo "  neu:      docs/anleitungen/index.md, docs/assets/images/uploads/.gitkeep"
  echo "  geändert: docker-compose.yml, docker/default.conf.template, Dockerfile; neu: HANDBUCH.md, cms/ (Kategorien, Inhaltstypen)"
  echo "  geändert: mkdocs.yml (nur 'hooks:' ergänzt), Index-Seiten troubleshooting/runbooks/standards (unsichtbarer Platzhalter für die Beitragsliste)"
  read -rp "Fortfahren? [j/N] " a; [ "$a" = "j" ] || [ "$a" = "J" ] || die "Abgebrochen"

  mkdir -p admin hooks docker/deployer docs/anleitungen docs/assets/images/uploads
  cp "$PKG_DIR"/admin/{index.html,config.yml,preview.css} admin/
  cp "$PKG_DIR/hooks/wiki_cms.py" hooks/
  cp "$PKG_DIR/overrides/main.html" overrides/
  if ! grep -q "cms_links:" mkdocs.yml; then
    if grep -q "^  generator: false" mkdocs.yml; then
      sed -i '/^  generator: false/a\  cms_links:\n    git_url: !ENV [GITEA_URL, ""]\n    git_repo: !ENV [GITEA_REPO, ""]' mkdocs.yml
    else
      c_warn "mkdocs.yml: Block 'extra: generator: false' nicht gefunden – Knöpfe bitte nach README von Hand ergänzen."
    fi
  fi
  cp "$PKG_DIR"/docker/deployer/{Dockerfile,deploy.py} docker/deployer/
  cp "$PKG_DIR/docker/default.conf.template" docker/default.conf.template
  cp "$PKG_DIR/docker-compose.yml" docker-compose.yml
  cp "$PKG_DIR/Dockerfile" Dockerfile
  cp "$PKG_DIR/.env.example" .env.example
  for d in HANDBUCH.md INSTALLATION-KURZ.md; do [ -f "$PKG_DIR/$d" ] && cp "$PKG_DIR/$d" . || true; done
  if [ -d "$PKG_DIR/cms" ]; then
    local cf
    while IFS= read -r cf; do
      local rel="${cf#"$PKG_DIR"/}"; [ -e "$rel" ] || { mkdir -p "$(dirname "$rel")"; cp "$cf" "$rel"; }
    done < <(find "$PKG_DIR/cms" -type f)
  fi
  touch docs/assets/images/uploads/.gitkeep
  [ -f docs/anleitungen/index.md ] || cp "$PKG_DIR/docs/anleitungen/index.md" docs/anleitungen/index.md
  grep -q '^hooks:' mkdocs.yml || printf '\n# Browser-Redaktion: neue Seiten automatisch in die Navigation, Formular-Seiten rendern\nhooks:\n  - hooks/wiki_cms.py\n' >> mkdocs.yml
  for idx in docs/troubleshooting/index.md docs/runbooks/index.md docs/standards/index.md; do
    [ -f "$idx" ] || continue
    grep -q 'cms:liste' "$idx" || printf '\n<!-- cms:liste titel="Neue Beiträge aus dem Editor" -->\n' >> "$idx"
  done
  mkdir -p docker/auth; touch docker/auth/.htpasswd

  c_info "Teste den Build lokal (mkdocs build --strict im Deploy-Image) ..."
  docker compose build -q deployer
  local out
  if ! out="$(docker run --rm --network none -v "$WIKI_DIR":/src:ro it-wiki-deployer:latest \
      sh -c 'mkdir -p /tmp/t && cd /tmp/t && cp -r /src/docs /src/mkdocs.yml /src/overrides /src/hooks . && { [ -d /src/cms ] && cp -r /src/cms . || true; } && mkdocs build --strict -d /tmp/t/site' 2>&1)"; then
    echo "$out" | tail -25 || true
    die "Testbuild fehlgeschlagen – nichts committet. Zurücksetzen: git checkout -- . && git clean -fd admin hooks docker/deployer docs/anleitungen"
  fi
  c_ok "Testbuild erfolgreich"

  git add -A
  git commit -q -m "Browser-Redaktion: Decap CMS, Navigation-Hook und Deploy-Dienst ergänzt"
  git_push -q origin main
  c_ok "Änderungen committet und nach Gitea gepusht"
}

# ----------------------------------------------------------------------------- deploy
cmd_deploy() {
  need_root; require_backup
  cd "$WIKI_DIR"
  [ -f .env ] || die ".env fehlt – zuerst bootstrap ausführen"
  mkdir -p docker/auth; [ -f docker/auth/.htpasswd ] || touch docker/auth/.htpasswd
  for k in WIKI_URL GITEA_URL GITEA_REPO OAUTH_CLIENT_ID GITEA_DEPLOY_TOKEN; do
    v="$(env_get .env "$k")"; [ -n "$v" ] && [[ "$v" != *AUS-GITEA* ]] && [[ "$v" != *SERVER-IP* ]] || die "Wert $k in .env fehlt"
  done
  docker network inspect gitea-net >/dev/null 2>&1 || die "Netzwerk gitea-net fehlt – läuft Gitea?"
  docker compose build -q deployer
  c_info "Erster Build aus Gitea (die bisherige Website läuft weiter) ..."
  docker compose run --rm --no-deps deployer /usr/local/bin/deploy.py --once || die "Build aus Gitea fehlgeschlagen – bisherige Website unverändert. Protokoll: docker compose run --rm deployer sh -c 'tail -50 /srv/site/_status/logs/*.log'"
  c_ok "Build erfolgreich – stelle Auslieferung um"
  docker compose up -d --remove-orphans
  sleep 3
  local port code; port="$(env_get .env WIKI_PORT)"; port="${port:-8080}"
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/")"
  [ "$code" = "200" ] || c_warn "Wiki antwortet mit HTTP $code – Logs: docker compose logs it-wiki"
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/admin/")"
  [ "$code" = "200" ] && c_ok "Redaktion erreichbar: $(env_get .env WIKI_URL)/admin/" || c_warn "/admin/ antwortet mit HTTP $code"
  c_ok "Build-Status: $(env_get .env WIKI_URL)/admin/build/"
}

# ----------------------------------------------------------------------------- editor
cmd_editor() {
  need_root; need_cmd jq jq
  local u="${1:-}" m="${2:-}"
  [ -n "$u" ] && [ -n "$m" ] || die "Aufruf: cms-install.sh editor BENUTZERNAME E-MAIL"
  ask_admin
  local pw r team_id
  pw="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 14)Aa1"
  r="$(api POST /admin/users "{\"username\":\"$u\",\"email\":\"$m\",\"password\":\"$pw\",\"must_change_password\":true,\"visibility\":\"private\"}")"
  [ "$(api_code "$r")" = "201" ] || die "Benutzer anlegen fehlgeschlagen: $(api_body "$r")"
  team_id="$(api_body "$(api GET "/orgs/$ORG/teams/search?q=$TEAM")" | jq -r --arg t "$TEAM" '.data[]? | select(.name==$t) | .id' | head -1)"
  r="$(api PUT "/teams/$team_id/members/$u")"
  case "$(api_code "$r")" in 204|200) ;; *) die "Team-Zuordnung fehlgeschlagen: $(api_body "$r")";; esac
  c_ok "Redakteur $u angelegt und Team $TEAM zugeordnet."
  echo "   Startpasswort (muss bei der ersten Anmeldung geändert werden): $pw"
  echo "   Bitte persönlich übergeben, nicht per E-Mail."
}

# ----------------------------------------------------------------------------- test
state_json() { (cd "$WIKI_DIR" && docker compose exec -T deployer cat /srv/site/_status/state.json 2>/dev/null) || echo '{}'; }
wait_build() { # COMMIT-SHA  -> gibt Ergebnis aus
  local sha="$1" res=""
  for _ in $(seq 1 40); do
    res="$(state_json | jq -r --arg s "$sha" '[.history[]? | select(.commit==$s)][0].ergebnis // empty')"
    [ -n "$res" ] && { echo "$res"; return; }
    sleep 5
  done
  echo "zeitüberschreitung"
}

cmd_test() {
  set +e
  need_cmd jq jq
  local port wiki gitea repo pass=0 fail=0
  port="$(env_get "$WIKI_DIR/.env" WIKI_PORT)"; port="${port:-8080}"
  wiki="http://127.0.0.1:$port"; gitea="$(gitea_url_local)"; repo="$(env_get "$WIKI_DIR/.env" GITEA_REPO)"
  t() { if [ "$2" = "0" ]; then c_ok "Test $1"; pass=$((pass+1)); else c_warn "Test $1 FEHLGESCHLAGEN"; fail=$((fail+1)); fi; }

  local body
  body="$(curl -fsS "$wiki/")"; grep -q 'md-content' <<<"$body"; t "1  Startseite / ohne Anmeldung erreichbar (HTTP 200)" $?
  body="$(curl -fsS "$wiki/admin/")"; grep -q 'decap-cms.js' <<<"$body"; t "2  /admin/ liefert die Redaktionsoberfläche" $?
  body="$(curl -fsS "$wiki/admin/config.yml")"; [ -n "$body" ] && ! grep -q '__[A-Z_]*__' <<<"$body"; t "2b config.yml: alle Platzhalter ersetzt" $?
  local c1 c2
  c1="$(curl -s -o /dev/null -w '%{http_code}' "$gitea/api/v1/repos/$repo")"
  c2="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"content":"dGVzdA==","message":"anonym"}' "$gitea/api/v1/repos/$repo/contents/docs/anonym-test.md")"
  [[ "$c1" =~ ^(401|403|404)$ && "$c2" =~ ^(401|403|404)$ ]]; t "3  Anonym: Repo nicht lesbar ($c1), Schreiben verweigert ($c2)" $?
  body="$(curl -s "$gitea/user/sign_up")"; grep -qiE "deaktiviert|disabled" <<<"$body"; t "3b Öffentliche Registrierung deaktiviert" $?
  [ "$(state_json | jq -r '.live.commit // empty')" != "" ]; t "8  Deploy-Dienst hat ein Live-Release" $?
  echo; echo "Bestanden: $pass, fehlgeschlagen: $fail"
  echo "Tests 4–7 und 9 (Anmeldung, Formular, Bild, Sichtbarkeit) werden im Browser durchgeführt – siehe README, Abschnitt Abnahmetests."
  echo "Test 10 (defekter Link blockiert Veröffentlichung): sudo bash scripts/cms-install.sh test-fehler"
}

cmd_test_fehler() {
  need_cmd jq jq; ask_admin
  set +e
  local repo port live_before r sha res f="docs/anleitungen/test-defekter-link.md"
  repo="$(env_get "$WIKI_DIR/.env" GITEA_REPO)"; port="$(env_get "$WIKI_DIR/.env" WIKI_PORT)"; port="${port:-8080}"
  live_before="$(state_json | jq -r '.live.commit')"
  local content; content="$(printf -- '---\nvorlage: anleitung\ndateiname: test-defekter-link\ntitle: Test defekter Link\nverwandte_troubleshooting:\n  - gibt-es-nicht\n---\nDieser Testbeitrag muss den Build scheitern lassen.\n' | base64 -w0)"
  r="$(api POST "/repos/$repo/contents/$f" "{\"content\":\"$content\",\"message\":\"Test 10: absichtlich defekter Link\",\"branch\":\"main\"}")"
  [ "$(api_code "$r")" = "201" ] || die "Testcommit fehlgeschlagen: $(api_body "$r")"
  sha="$(api_body "$r" | jq -r .commit.sha)"
  c_info "Testcommit ${sha:0:10} erstellt – warte auf Build ..."
  res="$(wait_build "$sha")"
  [ "$res" = "fehlgeschlagen" ] && c_ok "Build wurde blockiert (Ergebnis: $res)" || c_warn "Erwartet: fehlgeschlagen, erhalten: $res"
  [ "$(state_json | jq -r '.live.commit')" = "$live_before" ] && c_ok "Live-Version unverändert (${live_before:0:10})" || c_warn "Live-Version hat sich geändert"
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/")" = "200" ] && c_ok "Wiki weiterhin erreichbar" || c_warn "Wiki nicht erreichbar"
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/anleitungen/test-defekter-link/")" = "404" ] && c_ok "Fehlerhafte Seite wurde nicht veröffentlicht" || c_warn "Fehlerhafte Seite ist sichtbar"
  local fsha; fsha="$(api_body "$(api GET "/repos/$repo/contents/$f?ref=main")" | jq -r .sha)"
  r="$(api DELETE "/repos/$repo/contents/$f" "{\"sha\":\"$fsha\",\"message\":\"Test 10: Testbeitrag entfernt\",\"branch\":\"main\"}")"
  sha="$(api_body "$r" | jq -r .commit.sha)"
  c_info "Testbeitrag entfernt (${sha:0:10}) – warte auf Build ..."
  res="$(wait_build "$sha")"
  [ "$res" = "erfolgreich" ] && c_ok "Folgebuild erfolgreich – Ausgangszustand wiederhergestellt" || c_warn "Folgebuild: $res"
}

# ----------------------------------------------------------------------------- docker
cmd_docker() {
  need_root
  local missing=""
  for c in git jq curl; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
  if [ -n "$missing" ]; then c_info "Installiere:$missing"; apt-get update -q && apt-get install -y -q $missing; fi
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    c_ok "Docker ist bereits installiert: $(docker --version)"; return 0
  fi
  [ -r /etc/os-release ] && . /etc/os-release
  [ "${ID:-}" = "debian" ] || die "Automatische Installation nur für Debian. Bitte Docker nach https://docs.docker.com/engine/install/ installieren."
  c_info "Installiere Docker CE aus dem offiziellen Docker-Repository für Debian $VERSION_CODENAME"
  apt-get update -q
  apt-get install -y -q ca-certificates curl git jq
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $VERSION_CODENAME stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -q
  apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  c_ok "Docker installiert: $(docker --version)"
}

# Beispielbeiträge der Vorlage bei der Installation behalten oder entfernen
# (ohne Rückfrage: BEISPIELE=ja bzw. BEISPIELE=nein)
ask_beispiele() {
  cd "$WIKI_DIR"
  local files; files="$(find docs -type f -name 'beispiel-*.md' 2>/dev/null | sort)"
  [ -n "$files" ] || return 0
  local a="${BEISPIELE:-}"
  if [ -z "$a" ]; then
    echo
    echo "Die Vorlage enthält $(wc -l <<<"$files") Beispielbeiträge (Anleitung, Troubleshooting, Runbook, Standard, Checkliste)."
    read -rp "Mit Beispielen installieren? [J/n] " a
  fi
  case "$a" in
    n|N|nein|Nein|NEIN)
      if [ -d .git ] && git ls-files --error-unmatch $files >/dev/null 2>&1; then
        git config --global --add safe.directory "$WIKI_DIR" 2>/dev/null || true
        xargs git rm -q <<<"$files"
        git -c user.name="IT-Team" -c user.email="it-team@noreply.invalid" commit -q -m "Installation ohne Beispielbeiträge"
      else
        xargs rm -f <<<"$files"
      fi
      c_ok "Installation ohne Beispiele – das Wiki startet leer." ;;
    *)
      c_ok "Beispielbeiträge bleiben erhalten (später entfernen: cms-install.sh beispiele)" ;;
  esac
}

# ----------------------------------------------------------------------------- install (neue VM)
cmd_install() {
  need_root
  need_cmd docker "docker-ce  (oder: sudo bash scripts/cms-install.sh docker)"
  docker compose version >/dev/null 2>&1 || die "Docker-Compose-Plugin fehlt (sudo bash scripts/cms-install.sh docker)"
  need_cmd git git; need_cmd jq jq; need_cmd curl curl
  if [ "$(cd "$PKG_DIR" && pwd -P)" != "$(cd "$WIKI_DIR" 2>/dev/null && pwd -P || echo none)" ]; then
    [ -e "$WIKI_DIR" ] && die "$WIKI_DIR existiert bereits. Für ein bestehendes Wiki die Einzelschritte (backup, gitea, bootstrap, import, apply, deploy) verwenden."
    c_info "Kopiere Projekt nach $WIKI_DIR"
    cp -a "$PKG_DIR" "$WIKI_DIR"
    PKG_DIR="$WIKI_DIR"
  fi
  local ip; ip="$(server_ip)"
  echo "Server-IP: $ip"
  read -rp "Ist diese IP richtig? [j/N] " a; [ "$a" = "j" ] || [ "$a" = "J" ] || die "Bitte mit SERVER_IP=… erneut aufrufen."
  export SERVER_IP="$ip"
  ask_urls "$ip"
  echo "   Wiki:  $WIKI_URL"
  echo "   Gitea: $GITEA_URL"
  if [[ "$WIKI_URL" == https://* ]]; then
    echo "   Reverse Proxy: ${WIKI_URL#https://} -> http://$ip:8080   und   ${GITEA_URL#https://} -> http://$ip:3000"
  fi
  read -rp "Mit diesen Adressen installieren? [j/N] " a; [ "$a" = "j" ] || [ "$a" = "J" ] || die "Abgebrochen"
  ask_beispiele
  cmd_backup
  cmd_gitea
  cmd_bootstrap
  cmd_import
  cmd_deploy
  echo; cmd_test
  echo
  c_ok "Fertig. Wiki: $WIKI_URL/   Redaktion: $WIKI_URL/admin/   Gitea: $GITEA_URL/"
  if [[ "$WIKI_URL" == https://* ]]; then
    echo "   Im Reverse Proxy zwei Hosts mit HTTPS anlegen: ${WIKI_URL#https://} -> http://$ip:8080, ${GITEA_URL#https://} -> http://$ip:3000"
    echo "   Bis dahin ist alles lokal unter http://$ip:8080 erreichbar (Anmeldung in der Redaktion erst über die Domain)."
  fi
  echo "   Nächste Schritte: Redakteur anlegen (cms-install.sh editor NAME MAIL), Branch-Schutz in Gitea setzen, Test 10 (cms-install.sh test-fehler)."
}

# ----------------------------------------------------------------------------- adressen (IP <-> Domains umstellen)
cmd_adressen() {
  need_root; need_cmd jq jq; need_cmd curl curl
  local wenv="$WIKI_DIR/.env" genv="$GITEA_DIR/.env" ip old_wiki r cid app_id uris
  [ -f "$wenv" ] && [ -f "$genv" ] || die "$wenv oder $genv fehlt – zuerst installieren."
  ip="$(server_ip)"
  old_wiki="$(env_get "$wenv" WIKI_URL)"
  echo "Aktuell:  Wiki $(env_get "$wenv" WIKI_URL)   Gitea $(env_get "$wenv" GITEA_URL)"
  ask_urls "$ip"
  echo "Neu:      Wiki $WIKI_URL   Gitea $GITEA_URL"
  read -rp "Umstellen? [j/N] " a; [ "$a" = "j" ] || [ "$a" = "J" ] || die "Abgebrochen"
  cmd_backup
  ask_admin
  cp -a "$wenv" "$wenv.bak-$TS"; cp -a "$genv" "$genv.bak-$TS"
  for f in "$wenv" "$genv"; do env_set "$f" WIKI_URL "$WIKI_URL"; env_set "$f" GITEA_URL "$GITEA_URL"; done
  if [[ "$WIKI_URL" == https://* ]]; then env_set "$wenv" DECAP_HTTP_LOGIN false; else env_set "$wenv" DECAP_HTTP_LOGIN true; fi
  chmod 600 "$wenv" "$genv"
  c_ok ".env-Dateien angepasst (Sicherung: *.bak-$TS)"

  c_info "Starte Gitea mit neuer Adresse ..."
  (cd "$GITEA_DIR" && docker compose up -d --force-recreate) >/dev/null
  local i; for i in $(seq 1 60); do curl -fs -o /dev/null "$(gitea_url_local)/api/healthz" && break; sleep 2; done
  curl -fs -o /dev/null "$(gitea_url_local)/api/healthz" || die "Gitea antwortet nicht – Logs: cd $GITEA_DIR && docker compose logs"

  # OAuth-Weiterleitung ergänzen (alte Adresse bleibt erhalten)
  cid="$(env_get "$wenv" OAUTH_CLIENT_ID)"
  r="$(api GET "/user/applications/oauth2?limit=50")"
  app_id="$(api_body "$r" | jq -r --arg c "$cid" '.[]? | select(.client_id==$c) | .id' | head -1)"
  if [ -n "$app_id" ]; then
    uris="$(api_body "$r" | jq -c --arg c "$cid" --arg n "$WIKI_URL/admin/" '[.[] | select(.client_id==$c) | .redirect_uris[]] + [$n] | unique')"
    r="$(api PATCH "/user/applications/oauth2/$app_id" "{\"name\":\"Decap CMS (IT-Wiki)\",\"redirect_uris\":$uris,\"confidential_client\":false}")"
    [ "$(api_code "$r")" = "200" ] && c_ok "OAuth-Weiterleitung ergänzt: $WIKI_URL/admin/" || c_warn "OAuth-Anwendung nicht aktualisiert: $(api_body "$r")"
  else
    c_warn "OAuth-Anwendung gehört nicht dem Benutzer $API_USER – Weiterleitung $WIKI_URL/admin/ bitte in Gitea von Hand ergänzen (README: Adressen ändern)."
  fi

  c_info "Starte Deploy-Dienst neu und baue das Wiki mit den neuen Adressen ..."
  cd "$WIKI_DIR"
  docker compose up -d --force-recreate deployer >/dev/null
  docker compose exec -T deployer /usr/local/bin/deploy.py --force >/dev/null || die "Build fehlgeschlagen – Status: $WIKI_URL/admin/build/"
  c_ok "Fertig. Wiki: $WIKI_URL/   Redaktion: $WIKI_URL/admin/   Gitea: $GITEA_URL/"
  [ "$old_wiki" != "$WIKI_URL" ] && echo "   In der Redaktion einmal ab- und unter der neuen Adresse wieder anmelden."
  if [[ "$WIKI_URL" == https://* ]]; then
    echo "   Reverse Proxy: ${WIKI_URL#https://} -> http://$ip:8080   und   ${GITEA_URL#https://} -> http://$ip:3000"
  fi
}

# ----------------------------------------------------------------------------- beispiele (Beispielbeiträge der Vorlage entfernen)
cmd_beispiele() {
  need_root; ask_admin
  cd "$WIKI_DIR"
  git config --global --add safe.directory "$WIKI_DIR" 2>/dev/null || true
  local cred; cred="$(printf '%s:%s' "$API_USER" "$API_PASS" | base64 -w0)"
  git -c "http.extraHeader=Authorization: Basic $cred" pull -q --ff-only origin main || die "git pull fehlgeschlagen"
  local files; files="$(git ls-files 'docs/*beispiel-*.md')"
  [ -n "$files" ] || { c_ok "Keine Beispielbeiträge mehr vorhanden."; return 0; }
  echo "Diese Beispielbeiträge werden gelöscht (bleiben im Git-Verlauf erhalten):"; sed 's/^/  /' <<<"$files"
  read -rp "Löschen? [j/N] " a; [ "$a" = "j" ] || [ "$a" = "J" ] || die "Abgebrochen"
  cmd_backup
  xargs git rm -q <<<"$files"
  c_info "Testbuild (mkdocs build --strict) ..."
  local out
  if ! out="$(docker run --rm --network none -v "$WIKI_DIR":/src:ro it-wiki-deployer:latest \
      sh -c 'mkdir -p /tmp/t && cd /tmp/t && cp -r /src/docs /src/mkdocs.yml /src/overrides /src/hooks /src/cms . && mkdocs build --strict -d /tmp/t/site' 2>&1)"; then
    echo "$out" | grep -E "WARNING|ERROR" | head -20 || true
    git reset -q --hard HEAD
    die "Testbuild fehlgeschlagen (vermutlich verlinkt ein eigener Beitrag auf ein Beispiel) – nichts gelöscht."
  fi
  git commit -q -m "Beispielbeiträge der Vorlage entfernt"
  git -c "http.extraHeader=Authorization: Basic $cred" push -q origin main
  c_ok "Beispielbeiträge entfernt – das Wiki ist in etwa einer Minute aktualisiert."
}

# ----------------------------------------------------------------------------- uninstall (alles entfernen)
cmd_uninstall() {
  need_root
  local d
  for d in "$WIKI_DIR" "$GITEA_DIR"; do
    case "$d" in ""|/|/opt|/opt/|/home|/root|/usr|/etc|/var) die "Unsicherer Pfad: '$d' – Abbruch." ;; esac
  done
  echo "Deinstallation entfernt:"
  echo "  - Container it-wiki, it-wiki-deployer, gitea sowie Volumes, Netzwerk gitea-net und Image it-wiki-deployer"
  echo "  - $WIKI_DIR   (Wiki, Redaktion, alle Inhalte)"
  echo "  - $GITEA_DIR  (Gitea mit allen Benutzern, Repositories und Secrets)"
  echo "  - Backup-Eintrag in der root-Crontab (falls vorhanden)"
  echo "Vorher wird automatisch ein letztes Vollbackup nach $BACKUP_DIR erstellt."
  echo "Erhalten bleiben: Docker selbst und die Backups (sofern unten nicht anders gewählt)."
  echo
  local rm_images="n" rm_backups="n" a
  read -rp "Auch die heruntergeladenen Docker-Images (nginx, gitea, python) löschen? [j/N] " rm_images
  read -rp "Auch ALLE Backups in $BACKUP_DIR löschen (inkl. des eben erstellten)? [j/N] " rm_backups
  echo
  read -rp "Zum Bestätigen ENTFERNEN eintippen: " a
  [ "$a" = "ENTFERNEN" ] || die "Abgebrochen – nichts wurde entfernt."

  if [ -f "$WIKI_DIR/mkdocs.yml" ]; then
    c_info "Letztes Vollbackup vor dem Entfernen ..."
    cmd_backup
  elif [ -d "$WIKI_DIR" ] || [ -d "$GITEA_DIR" ]; then
    c_warn "$WIKI_DIR/mkdocs.yml fehlt – kein Backup möglich."
    read -rp "Trotzdem ohne Backup entfernen? [j/N] " a; [ "$a" = "j" ] || [ "$a" = "J" ] || die "Abgebrochen – nichts wurde entfernt."
  fi

  if [ -f "$WIKI_DIR/docker-compose.yml" ]; then
    (cd "$WIKI_DIR" && docker compose down -v --remove-orphans) || c_warn "docker compose down (Wiki) meldete einen Fehler"
  fi
  if [ -f "$GITEA_DIR/docker-compose.yml" ]; then
    (cd "$GITEA_DIR" && docker compose down -v --remove-orphans) || c_warn "docker compose down (Gitea) meldete einen Fehler"
  fi
  docker rm -f it-wiki it-wiki-deployer gitea >/dev/null 2>&1 || true
  docker network rm gitea-net >/dev/null 2>&1 || true
  docker rmi it-wiki-deployer:latest >/dev/null 2>&1 || true
  c_ok "Container, Volumes und Netzwerk entfernt"

  if crontab -l 2>/dev/null | grep -qE "cms-install\.sh|/opt/backups/it-wiki-"; then
    crontab -l 2>/dev/null | grep -vE "cms-install\.sh|/opt/backups/it-wiki-" | crontab -
    c_ok "Backup-Eintrag aus der root-Crontab entfernt"
  fi

  cd /
  rm -rf -- "$WIKI_DIR" "$GITEA_DIR"
  c_ok "$WIKI_DIR und $GITEA_DIR gelöscht"

  if [ "$rm_images" = "j" ] || [ "$rm_images" = "J" ]; then
    docker rmi nginx:stable-alpine "$GITEA_IMAGE" python:3.12-slim >/dev/null 2>&1 || true
    c_ok "Docker-Images entfernt (soweit nicht anderweitig benutzt)"
  fi
  if [ "$rm_backups" = "j" ] || [ "$rm_backups" = "J" ]; then
    rm -f -- "$BACKUP_DIR"/it-wiki-*.tar.gz "$BACKUP_DIR"/it-wiki-*.tar.gz.list "$BACKUP_DIR"/it-wiki-*.tar.gz.sha256
    rm -rf -- "$BACKUP_DIR"/docker-meta-*
    rmdir "$BACKUP_DIR" 2>/dev/null || true
    c_ok "Backups gelöscht"
  else
    local last; last="$(ls -1t "$BACKUP_DIR"/it-wiki-*.tar.gz 2>/dev/null | head -1 || true)"
    [ -n "$last" ] && echo "   Letztes Backup: $last  (Wiederherstellung: siehe Handbuch „Restore“)"
  fi
  c_ok "Deinstallation abgeschlossen. Docker selbst ist weiterhin installiert."
}

# ----------------------------------------------------------------------------- update (neue Paketversion einspielen)
cmd_update() {
  need_root
  [ "$(cd "$PKG_DIR" && pwd -P)" != "$(cd "$WIKI_DIR" && pwd -P)" ] || die "Bitte das neue Paket in einen anderen Ordner entpacken (z. B. ~/it-wiki-neu) und dessen Skript aufrufen."
  [ -d "$WIKI_DIR/.git" ] || die "$WIKI_DIR ist noch kein Git-Repository – zuerst installieren."
  cmd_backup
  ask_admin
  cd "$WIKI_DIR"
  git config --global --add safe.directory "$WIKI_DIR" 2>/dev/null || true
  git diff --quiet && git diff --cached --quiet || die "Nicht committete Änderungen in $WIKI_DIR – bitte zuerst committen oder verwerfen."
  local cred; cred="$(printf '%s:%s' "$API_USER" "$API_PASS" | base64 -w0)"
  git -c "http.extraHeader=Authorization: Basic $cred" pull -q --ff-only origin main || die "git pull fehlgeschlagen"
  c_ok "Aktueller Stand aus Gitea geholt (inkl. aller Redaktions-Beiträge)"

  echo "Folgende Dateien werden aktualisiert:"
  echo "  admin/config.yml, admin/index.html, admin/preview.css, hooks/wiki_cms.py, overrides/main.html, scripts/cms-install.sh, Dokumentation (*.md im Hauptordner)"
  echo "  mkdocs.yml: nur der Block für die Knöpfe „Redaktion“ und „Git“ wird ergänzt (Navigation bleibt unverändert)"
  echo "  cms/ (nur fehlende Dateien; vorhandene Kategorien und Inhaltstypen bleiben unverändert)"
  read -rp "Fortfahren? [j/N] " a; [ "$a" = "j" ] || [ "$a" = "J" ] || die "Abgebrochen"

  # bisherige Kategorien aus dem Auswahlfeld der alten config.yml übernehmen
  mkdir -p cms/kategorien cms/inhaltstypen
  if [ -f admin/config.yml ] && grep -q 'widget: select' admin/config.yml; then
    docker run --rm -i --user 0 --network none -v "$WIKI_DIR":/w it-wiki-deployer:latest python3 - <<'PY'
import os, re, yaml
cfg = yaml.safe_load(open('/w/admin/config.yml', encoding='utf-8'))
def slug(t):
    t = t.lower()
    for a, b in (("ä","ae"),("ö","oe"),("ü","ue"),("ß","ss")): t = t.replace(a, b)
    return re.sub(r"[^a-z0-9]+", "-", t).strip("-")
for col in cfg.get('collections', []):
    for f in col.get('fields', []):
        if f.get('name') == 'kategorie' and f.get('widget') == 'select':
            for i, opt in enumerate(f.get('options', []), 1):
                name = opt['label'] if isinstance(opt, dict) else str(opt)
                path = f"/w/cms/kategorien/{slug(name)}.yml"
                if not os.path.exists(path):
                    with open(path, 'w', encoding='utf-8') as fh:
                        yaml.safe_dump({'dateiname': slug(name), 'title': name, 'reihenfolge': i * 10}, fh, allow_unicode=True, sort_keys=False)
                    print('  Kategorie übernommen:', name)
PY
  fi
  cp "$PKG_DIR"/admin/{config.yml,index.html,preview.css} admin/
  cp "$PKG_DIR/hooks/wiki_cms.py" hooks/
  cp "$PKG_DIR/overrides/main.html" overrides/
  if ! grep -q "cms_links:" mkdocs.yml; then
    if grep -q "^  generator: false" mkdocs.yml; then
      sed -i '/^  generator: false/a\  cms_links:\n    git_url: !ENV [GITEA_URL, ""]\n    git_repo: !ENV [GITEA_REPO, ""]' mkdocs.yml
    else
      c_warn "mkdocs.yml: Block 'extra: generator: false' nicht gefunden – Knöpfe bitte nach README von Hand ergänzen."
    fi
  fi
  cp "$PKG_DIR/scripts/cms-install.sh" scripts/
  for f in README.md HANDBUCH.md INSTALLATION-KURZ.md CHANGELOG.md LICENSE TESTPROTOKOLL.md; do
    [ -f "$PKG_DIR/$f" ] && cp "$PKG_DIR/$f" . || true
  done
  local f rel
  while IFS= read -r f; do
    rel="${f#"$PKG_DIR"/}"
    [ -e "$rel" ] || { mkdir -p "$(dirname "$rel")"; cp "$f" "$rel"; }
  done < <(find "$PKG_DIR/cms" -type f)
  grep -qxF -- "gitea" .dockerignore 2>/dev/null || printf '.env\ngitea\n' >> .dockerignore

  c_info "Testbuild (mkdocs build --strict) ..."
  local out
  if ! out="$(docker run --rm --network none -v "$WIKI_DIR":/src:ro it-wiki-deployer:latest \
      sh -c 'mkdir -p /tmp/t && cd /tmp/t && cp -r /src/docs /src/mkdocs.yml /src/overrides /src/hooks /src/cms . && mkdocs build --strict -d /tmp/t/site' 2>&1)"; then
    echo "$out" | tail -25 || true
    die "Testbuild fehlgeschlagen – nichts committet. Zurücksetzen: cd $WIKI_DIR && git checkout -- . && git clean -fd cms"
  fi
  c_ok "Testbuild erfolgreich"
  git add -A
  if git diff --cached --quiet; then c_ok "Bereits aktuell – keine Änderungen"; return 0; fi
  git commit -q -m "Update auf neue Paketversion (Redaktion, Hook, Kopfzeilen-Knöpfe)"
  git -c "http.extraHeader=Authorization: Basic $cred" push -q origin main
  c_ok "Aktualisierung nach Gitea gepusht – der Deploy-Dienst veröffentlicht sie in etwa einer Minute."
  echo "   Danach die Redaktion mit Strg+F5 neu laden."
}

# ----------------------------------------------------------------------------- status
cmd_status() {
  cd "$WIKI_DIR"
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E 'NAMES|it-wiki|gitea' || true
  echo; docker compose logs --tail 15 deployer 2>/dev/null || true
  echo; echo "Releases:"; docker compose exec -T deployer /usr/local/bin/deploy.py --list 2>/dev/null || true
}

case "${1:-}" in
  docker) cmd_docker ;;
  install) cmd_install ;;
  update) cmd_update ;;
  adressen) cmd_adressen ;;
  beispiele) cmd_beispiele ;;
  uninstall) cmd_uninstall ;;
  check) cmd_check ;;
  backup) cmd_backup ;;
  gitea) cmd_gitea ;;
  bootstrap) cmd_bootstrap ;;
  import) cmd_import ;;
  apply) cmd_apply ;;
  deploy) cmd_deploy ;;
  editor) shift; cmd_editor "$@" ;;
  status) cmd_status ;;
  test) cmd_test ;;
  test-fehler) cmd_test_fehler ;;
  *) sed -n '2,39p' "$0"; exit 1 ;;
esac

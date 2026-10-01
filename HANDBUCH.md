# Handbuch – Betrieb der IT-Wissensdatenbank mit Browser-Redaktion

Die Wissensdatenbank ist eine MkDocs-Material-Website. Leser rufen sie ohne Anmeldung auf. Geschrieben wird in einer Redaktionsoberfläche (Decap CMS) unter `/admin/`. Die Anmeldung dort läuft über Gitea-Konten. Jede Änderung wird als Git-Commit in einem internen Gitea-Repository gespeichert. Ein Deploy-Dienst baut die Website danach mit `mkdocs build --strict` neu und veröffentlicht sie nur, wenn der Build fehlerfrei ist.

Alles läuft auf dem eigenen Server. Es wird keine Cloud genutzt, und alle Komponenten sind kostenlos (Open Source).

Kurzfassung der Installation: [INSTALLATION-KURZ.md](INSTALLATION-KURZ.md). Projektübersicht: [README.md](README.md).

---

## Architekturübersicht

```text
 Leser (Browser)                         Redakteur (Browser)
      │  http://SERVER-IP:8080/               │  http://SERVER-IP:8080/admin/
      ▼                                       ▼
┌──────────────────────────────┐     ┌──────────────────────────────┐
│ it-wiki  (nginx, read-only)  │     │ Decap CMS (statische Dateien │
│  /         → Live-Release    │◄────│ unter /admin/, läuft im      │
│  /admin/   → Redaktion       │     │ Browser des Redakteurs)      │
│  /admin/build/ → Build-Status│     └──────────────┬───────────────┘
└──────────────▲───────────────┘          OAuth-Login (PKCE) + Git-API
               │ Volume wiki-site (ro)                │
┌──────────────┴───────────────┐     ┌──────────────▼───────────────┐
│ deployer (Python, mkdocs)    │     │ gitea  http://SERVER-IP:3000 │
│ fragt alle 30 s den Branch   │────►│ Benutzer, Rechte, privates   │
│ main ab (nur lesen), baut    │ git │ Repo it-team/it-wiki, SQLite │
│ strict, schaltet atomar um   │     └──────────────────────────────┘
└──────────────────────────────┘
```

Ablauf einer Änderung:

1. Ein Redakteur meldet sich unter `/admin/` mit seinem Gitea-Konto an und füllt ein Formular aus.
2. Beim Klick auf „Veröffentlichen“ schreibt Decap CMS eine Markdown-Datei (und hochgeladene Bilder) als Commit in den Branch `main`.
3. Der Deploy-Dienst erkennt den neuen Commit nach spätestens 30 Sekunden. Er exportiert genau diesen Stand und baut ihn mit `mkdocs build --strict` in einen neuen Release-Ordner.
4. Wenn der Build erfolgreich ist, stellt der Dienst den Symlink `current` atomar auf das neue Release um. Wenn er fehlschlägt, bleibt die bisherige Version online, und das Protokoll steht unter `/admin/build/`.

## Komponenten

| Komponente | Aufgabe | Ort |
|---|---|---|
| nginx (`it-wiki`) | liefert Website, `/admin/` und Build-Status aus; schreibgeschützter Container | `/opt/it-wiki/docker-compose.yml` |
| Deploy-Dienst (`it-wiki-deployer`) | Polling, Build, Veröffentlichung, Rollback; kein Docker-Socket, keine Root-Rechte, kein eingehender Port | `/opt/it-wiki/docker/deployer/` |
| Decap CMS 3.16.3 | Redaktionsoberfläche; wird beim Image-Build einmal von unpkg.com geladen (wie die Python-Pakete) und per SHA-256 geprüft, zur Laufzeit gibt es kein CDN | `/opt/it-wiki/admin/` |
| MkDocs-Hook | ergänzt neue Seiten automatisch in der Navigation und erzeugt aus den Formularfeldern eine saubere Seite | `/opt/it-wiki/hooks/wiki_cms.py` |
| Gitea 1.27.3 (rootless) | Benutzer, Rechte, Git-Repository, OAuth-Anmeldung | `/opt/gitea/` |

Warum SQLite statt PostgreSQL? Gitea wird hier nur von wenigen Personen für ein einziges Repository genutzt. SQLite braucht keinen zusätzlichen Container, kein Datenbankpasswort und keine eigene Wartung. Das Backup ist eine einzige Datei in `/opt/gitea/data`. PostgreSQL lohnt sich erst bei vielen gleichzeitigen Benutzern oder Repositories und lässt sich später mit `gitea dump` migrieren.

## URLs und Ports

| Adresse | Zweck | Anmeldung |
|---|---|---|
| `http://SERVER-IP:8080/` | Wiki für Leser | keine |
| `http://SERVER-IP:8080/admin/` | Redaktion (Decap CMS) | Gitea-Konto mit Schreibrecht |
| `http://SERVER-IP:8080/admin/build/` | Build-Status und Protokolle | keine (enthält nur Commit-Titel und Build-Ausgabe) |
| `http://SERVER-IP:3000/` | Gitea (Benutzer, Repository, Verlauf) | Gitea-Konto |

Ports: 8080/tcp für das Wiki und 3000/tcp für Gitea. SSH für Git ist abgeschaltet, Git läuft über HTTP. Wenn eine Firewall aktiv ist, sollten beide Ports nur aus dem internen Netz erreichbar sein.

## Start, Stop, Update

```bash
# Wiki (nginx + Deploy-Dienst)
cd /opt/it-wiki
docker compose up -d                 # starten
docker compose stop                  # anhalten
docker compose ps                    # Status
docker compose logs -f deployer      # Build-Meldungen live

# Gitea
cd /opt/gitea
docker compose up -d
docker compose stop
docker compose logs -f gitea

# Sofort bauen statt auf das nächste Intervall zu warten
cd /opt/it-wiki && docker compose exec deployer /usr/local/bin/deploy.py --force
```

Reihenfolge beim Serverstart: Docker startet beide Projekte automatisch (`restart: unless-stopped`). Wenn Gitea noch nicht bereit ist, wiederholt der Deploy-Dienst die Abfrage einfach beim nächsten Intervall.

## Backup und Restore

### Was gesichert wird

- `/opt/it-wiki`: Projekt, Git-Repository-Kopie, `.env` mit Token
- `/opt/gitea`: Datenbank, Repositories, Konfiguration, `.env` mit Secrets
- Docker-Metadaten: `docker ps`, `docker inspect`, aufgelöste Compose-Dateien

Die gebauten Releases im Volume `wiki-site` müssen nicht gesichert werden, weil sie jederzeit aus Git neu entstehen.

```bash
# Vollbackup (hält Gitea für wenige Sekunden an)
sudo bash /opt/it-wiki/scripts/cms-install.sh backup

# alternativ manuell
sudo tar -czf /opt/backups/it-wiki-$(date +%F-%H%M).tar.gz /opt/it-wiki /opt/gitea
sudo tar -tzf /opt/backups/it-wiki-JJJJ-MM-TT-HHMM.tar.gz | head    # prüfen
```

Täglich automatisch um 02:30 Uhr (als root mit `sudo crontab -e`):

```cron
30 2 * * * cd /opt/gitea && docker compose stop gitea && tar -czf /opt/backups/it-wiki-$(date +\%F).tar.gz /opt/it-wiki /opt/gitea; cd /opt/gitea && docker compose start gitea; find /opt/backups -name 'it-wiki-*.tar.gz' -mtime +30 -delete
```

Die Backups sollten zusätzlich auf ein anderes System kopiert werden, zum Beispiel ein NAS oder das vorhandene Backup-System.

### Restore

```bash
cd /opt/it-wiki && docker compose down          # Volumes bleiben erhalten
cd /opt/gitea   && docker compose down
sudo mv /opt/it-wiki /opt/it-wiki.defekt-$(date +%F)
sudo mv /opt/gitea   /opt/gitea.defekt-$(date +%F)
sudo tar -xzf /opt/backups/it-wiki-JJJJ-MM-TT-HHMM.tar.gz -C /
cd /opt/gitea   && docker compose up -d
cd /opt/it-wiki && docker compose up -d
docker compose exec deployer /usr/local/bin/deploy.py --force
```

Einzelne Artikel stellen Sie ohne Restore über den Git-Verlauf wieder her (siehe „Artikel ändern“).

Zurück zum Zustand vor der CMS-Erweiterung: Das Backup aus Phase 1 zurückspielen und `docker compose up -d --build` mit der alten `docker-compose.yml` ausführen. Alternativ in Git den Commit „Browser-Redaktion: …“ mit `git revert` zurücknehmen.

## Neuinstallation auf einer neuen VM

Das Repository enthält ein leeres Wiki mit Beispielbeiträgen, die Browser-Redaktion, Gitea und den Deploy-Dienst. Es lässt sich auf einer leeren Debian-VM (12 oder 13) in einem Durchlauf installieren.

Voraussetzungen:
- Debian-VM mit fester IP-Adresse
- 2 GB RAM und 10 GB freier Speicher genügen
- Internetzugang während der Installation (für Docker-Images und Python-Pakete)
- Ports 8080 und 3000 frei

```bash
# 1. Repository nach /opt/it-wiki klonen (vollständiger Klon, kein --depth)
sudo apt update && sudo apt install -y git
sudo git clone https://github.com/ben101111/it-wiki.git /opt/it-wiki
cd /opt/it-wiki
# alternativ: Release-ZIP herunterladen, entpacken und den Ordner nach /opt/it-wiki verschieben

# 2. Docker CE und Compose-Plugin aus dem offiziellen Docker-Repository installieren (falls nicht vorhanden)
sudo bash scripts/cms-install.sh docker

# 3. Alles einrichten: Backup, Gitea, Admin, Repo, Team, OAuth, erster Commit, Build, Start, Tests
sudo bash scripts/cms-install.sh install
```

Das Skript fragt nur wenige Dinge ab:
- Bestätigung der erkannten Server-IP. Ist sie falsch, rufen Sie das Skript mit `sudo SERVER_IP=192.168.10.20 bash …` auf, ohne spitze Klammern.
- Wie Wiki und Gitea erreichbar sein sollen:
  - **1 – über die IP:** `http://IP:8080` und `http://IP:3000`
  - **2 – über eigene Domains:** Sie geben zwei Domains ein, zum Beispiel `wiki.firma.de` und `git.firma.de`. Das Skript setzt automatisch `https://` davor und richtet alles für HTTPS hinter einem Reverse Proxy ein, siehe „Zugriff über Domains (Reverse Proxy)“.
- Ob das Wiki mit Beispielbeiträgen oder komplett leer starten soll. Beispiele lassen sich später mit `cms-install.sh beispiele` entfernen.
- Benutzername, E-Mail und Passwort des ersten Gitea-Administrators

Ohne Rückfragen zu Adressen und Beispielen geht es auch so:

```bash
sudo WIKI_URL=https://wiki.firma.de GITEA_URL=https://git.firma.de BEISPIELE=nein bash scripts/cms-install.sh install
```

Alles andere entsteht automatisch: Secrets, OAuth-Client-ID, Deploy-Token, `.env`-Dateien. Am Ende zeigt es die Adressen und das Ergebnis der automatischen Tests an.

Danach noch:

```bash
sudo bash scripts/cms-install.sh editor vorname.nachname name@firma.de   # Redakteur anlegen
sudo bash scripts/cms-install.sh test-fehler                             # Test 10
```

Branch-Schutz in Gitea einrichten (siehe „Repository verwalten“) und die tägliche Sicherung per Cron einrichten (siehe „Backup und Restore“).

Hinweis: Wenn eine Firewall (`ufw`, `nftables`) aktiv ist, müssen die Ports 8080 und 3000 aus dem internen Netz erlaubt sein, zum Beispiel mit `sudo ufw allow from 192.168.10.0/24 to any port 8080,3000 proto tcp`.

Die folgenden Abschnitte beschreiben die Einzelschritte. Sie werden nur gebraucht, wenn ein bereits laufendes Wiki ohne Redaktion erweitert werden soll.

## Erweiterung eines bestehenden Wikis (Einzelschritte)

Für ein bereits laufendes MkDocs-Material-Wiki ohne Redaktion. Voraussetzungen: Debian mit Docker und Docker Compose (läuft bereits), das bestehende Wiki in `/opt/it-wiki` und freier Port 3000.

```bash
sudo apt install -y git jq curl
# dieses Repository in einen eigenen Ordner klonen (nicht nach /opt/it-wiki)
sudo git clone https://github.com/ben101111/it-wiki.git /opt/it-wiki-cms
cd /opt/it-wiki-cms
sudo bash scripts/cms-install.sh check        # 1. Bestand prüfen (ändert nichts)
sudo bash scripts/cms-install.sh backup       # 2. Vollbackup nach /opt/backups, wird geprüft
sudo SERVER_IP=192.168.10.20 bash scripts/cms-install.sh gitea   # 3. Gitea starten, ersten Admin anlegen
sudo SERVER_IP=192.168.10.20 bash scripts/cms-install.sh bootstrap  # 4. Organisation, Repo, Team, Deploy-Benutzer, OAuth-App
sudo bash scripts/cms-install.sh import       # 5. bestehendes Wiki als ersten Commit nach Gitea
sudo bash scripts/cms-install.sh apply        # 6. CMS-Dateien einspielen, Testbuild, Commit, Push
sudo bash scripts/cms-install.sh deploy       # 7. Deploy-Dienst starten, Auslieferung umstellen
sudo bash scripts/cms-install.sh editor max.mustermann max@firma.de   # 8. Redakteur anlegen
sudo bash scripts/cms-install.sh test         # 9. automatische Abnahmetests
sudo bash scripts/cms-install.sh test-fehler  # 10. defekter Link blockiert Veröffentlichung
```

Jeder Schritt kann wiederholt werden. Die Schritte 3 bis 7 brechen ab, wenn kein Backup aus den letzten 12 Stunden existiert. Das Skript löscht nichts. Ersetzte Compose-Dateien bleiben im Backup und im Git-Verlauf erhalten.

Was sich am bestehenden Projekt ändert:

| Datei | Änderung |
|---|---|
| `mkdocs.yml` | nur drei Zeilen am Ende: `hooks: - hooks/wiki_cms.py`; Navigation, Theme und Plugins bleiben unverändert |
| `docs/troubleshooting/index.md`, `docs/runbooks/index.md`, `docs/standards/index.md` | unsichtbarer Platzhalter `<!-- cms:liste titel="…" -->` am Ende; die Liste erscheint erst, wenn es Editor-Beiträge gibt |
| `docs/anleitungen/index.md` | neu: Übersichtsseite für den neuen Bereich „Anleitungen“ |
| `docker-compose.yml` | nginx-Image statt eigenem Build plus Deploy-Dienst; Port, Basic-Auth-Schalter und Sicherheitsoptionen wie bisher |
| `docker/default.conf.template` | Wurzelverzeichnis `/srv/site/current`, zusätzlich `/admin/` und `/admin/build/`; Header, Caching und 404-Seite wie bisher |
| `Dockerfile` | bleibt als Notfallvariante ohne Gitea nutzbar |

Für Leser ändert sich nur, dass in der Navigation der Bereich „Anleitungen“ erscheint, sobald es ihn gibt, und dass neue Seiten hinzukommen. Theme, Farben, Suche, Tags und alle bestehenden Seiten bleiben gleich. Im lokalen Vergleich alter und neuer Builds war außer der Tag-Übersicht (neue Tags) kein Seiteninhalt verändert.

So wird neuen Seiten die Navigation zugeordnet: `mkdocs.yml` enthält eine feste `nav:`. Der Hook `hooks/wiki_cms.py` hängt beim Build jede Markdown-Datei, die dort noch nicht steht, an den Navigationsbereich ihres Ordners an. Gefunden wird der Bereich über die `index.md` des Ordners. Für `docs/anleitungen/` legt der Hook den Bereich „Anleitungen“ vor „Troubleshooting“ an. Die Datei `mkdocs.yml` wird dabei nicht verändert. Bestehende Einträge bleiben in Reihenfolge und Titel gleich.

## Abnahmetests

| Nr. | Test | Durchführung | Erwartung |
|---|---|---|---|
| 1 | `/` unverändert | `cms-install.sh test`; Startseite und einige Artikel im Browser ansehen | HTTP 200 ohne Anmeldung, gleiches Aussehen |
| 2 | `/admin/` zeigt Login | Browser: `http://SERVER-IP:8080/admin/` | Knopf „Mit Gitea einloggen“ |
| 3 | Anonym kein Schreiben | `cms-install.sh test` (prüft die API ohne Anmeldung); im Browser ohne Login gibt es kein Formular | Repo 403/404, Schreiben 401/403 |
| 4 | Redakteur-Anmeldung | Test-Redakteur anlegen (`editor`), Login über `/admin/`, Anwendung autorisieren | Übersicht mit vier Bereichen |
| 5 | Anleitung per Formular | „Anleitungen“ → „+ Anleitung“ → Titel „DNS-Forwarder einrichten (Test)“ → Felder füllen → Veröffentlichen | „Veröffentlicht“, Dateiname `dns-forwarder-einrichten-test` |
| 6 | Bild-Upload | im Formular unter „Screenshots/Bilder“ ein PNG hochladen | Bild in der Vorschau |
| 7 | Markdown im Repo | Gitea → `it-team/it-wiki` → `docs/anleitungen/dns-forwarder-einrichten-test.md` und `docs/assets/images/uploads/<bild>` | Frontmatter und Markdown-Text, Commit vom Redakteur |
| 8 | Build ausgelöst | `/admin/build/` | neuer Eintrag „erfolgreich“ nach etwa 30 bis 60 Sekunden |
| 9 | Seite sichtbar | Wiki → Navigation „Anleitungen“ | Seite mit Steckbrief, Abschnitten und Bild |
| 10 | Defekter Link blockiert | `cms-install.sh test-fehler` | Build „fehlgeschlagen“, Live-Version unverändert, Testseite 404; danach wird automatisch aufgeräumt |

Den Test-Redakteur und den Testartikel nach der Abnahme in Gitea löschen (Artikel: Datei löschen; Benutzer: Website-Administration → Benutzerkonten → Benutzer → Löschen).

## Gitea-Benutzerverwaltung

### Erster Administrator

Das Installationsskript legt ihn an (`cms-install.sh gitea`). Manuell geht es so:

```bash
docker exec -it gitea gitea admin user create --admin \
  --username VORNAME.NACHNAME --email name@firma.de --random-password --must-change-password
```

Das Startpasswort wird einmal angezeigt und muss bei der ersten Anmeldung unter `http://SERVER-IP:3000/user/login` geändert werden. Danach empfiehlt sich unter „Einstellungen → Sicherheit“ die Zwei-Faktor-Anmeldung (TOTP).

Passwort vergessen:

```bash
docker exec -it gitea gitea admin user change-password --username NAME --password 'NeuesPasswort123' --must-change-password
```

### Struktur

| Element | Wert | Zweck |
|---|---|---|
| Organisation | `it-team` (privat) | Besitzer des Repositorys |
| Repository | `it-team/it-wiki` (privat) | Inhalte des Wikis |
| Team „Owners“ | Administratoren | alles, auch Löschen, Einstellungen, Branch-Schutz |
| Team „Redaktion“ | Schreiben (Code) | Artikel anlegen und ändern über `/admin/` |
| Benutzer `wiki-deploy` | Lesen (Mitarbeiter) | technischer Zugang des Deploy-Dienstes, Token in `/opt/it-wiki/.env` |
| OAuth-Anwendung „Decap CMS (IT-Wiki)“ | öffentlicher Client | Anmeldung an `/admin/` |

Öffentliche Registrierung ist abgeschaltet (`DISABLE_REGISTRATION=true`). Ohne Anmeldung zeigt Gitea nichts an (`REQUIRE_SIGNIN_VIEW=true`), und alle Repositories sind privat (`FORCE_PRIVATE=true`).

### Redakteur anlegen

Per Skript (legt das Konto an, vergibt ein Startpasswort und ordnet es dem Team „Redaktion“ zu):

```bash
sudo bash /opt/it-wiki/scripts/cms-install.sh editor max.mustermann max.mustermann@firma.de
```

In der Gitea-Oberfläche:

1. Als Administrator anmelden und „Website-Administration“ (Profilmenü) → „Benutzerkonten“ → „Benutzerkonto erstellen“ öffnen.
2. Benutzername, E-Mail und Passwort eintragen und „Passwortänderung erforderlich“ anhaken.
3. Organisation `it-team` → „Teams“ → „Redaktion“ → „Teammitglied hinzufügen“ öffnen und den Benutzer eintragen.
4. Den Zugang persönlich übergeben. Der Redakteur meldet sich einmal unter `http://SERVER-IP:3000` an und ändert sein Passwort.

### Berechtigungen vergeben oder entziehen

- Schreiben (Artikel bearbeiten): Mitglied im Team „Redaktion“
- Nur lesen in Gitea (Verlauf ansehen, nicht bearbeiten): eigenes Team mit Berechtigung „Lesen“ anlegen. Für das Wiki selbst ist keine Anmeldung nötig.
- Entziehen: Benutzer aus dem Team entfernen. Bestehende Decap-Anmeldungen verlieren ihr Schreibrecht sofort, weil Gitea jede Änderung prüft.
- Sperren: Website-Administration → Benutzerkonten → Benutzer → „Anmeldung deaktivieren“.
- Administratoren: nur Mitglieder des Teams „Owners“ der Organisation. Gitea-Admins nur für den Betrieb.

### Repository verwalten

- Verlauf: `it-team/it-wiki` → „Commits“. Jeder Commit nennt Autor, Zeit und geänderte Dateien.
- Branch-Schutz (empfohlen): Repository → Einstellungen → Branches → Regel für `main` mit „Force-Push deaktivieren“ und „Löschen des Branches verhindern“. Unter „Push erlauben“ eine Whitelist mit den Teams „Owners“ und „Redaktion“ eintragen. Pull-Request-Pflicht bitte nicht aktivieren, weil Decap CMS sonst nicht mehr speichern kann.
- Die OAuth-Anwendung steht beim Admin-Konto unter „Einstellungen → Anwendungen → OAuth2-Anwendungen“.

### OAuth-Anwendung manuell anlegen

Das Skript `bootstrap` erledigt das automatisch. Manuell:

1. Als Administrator in Gitea anmelden und „Einstellungen“ → „Anwendungen“ → „Neue OAuth2-Anwendung erstellen“ öffnen.
2. Anwendungsname: `Decap CMS (IT-Wiki)`
3. Weiterleitungs-URI: `http://SERVER-IP:8080/admin/`. Sie muss exakt so lauten, mit `/admin/` und abschließendem Schrägstrich.
4. „Vertraulicher Client“ (Confidential Client) nicht anhaken. Decap CMS nutzt PKCE und braucht kein Client-Secret.
5. Speichern und die angezeigte Client-ID in `/opt/it-wiki/.env` als `OAUTH_CLIENT_ID=` eintragen. Das Client-Secret wird nicht benötigt und nirgends gespeichert.
6. Mit `cd /opt/it-wiki && docker compose restart deployer && docker compose exec deployer /usr/local/bin/deploy.py --force` übernehmen.

## Selbst einzutragende Werte

| Platzhalter | Datei | Bedeutung | Beispiel |
|---|---|---|---|
| `SERVER-IP` | `/opt/gitea/.env`, `/opt/it-wiki/.env` | IP oder DNS-Name des Servers, so wie Clients ihn aufrufen | `192.168.10.20` oder `wiki.firma.local` |
| `WIKI_URL` | beide `.env` | Adresse des Wikis ohne Schrägstrich am Ende | `http://192.168.10.20:8080` |
| `GITEA_URL` | beide `.env` | Adresse von Gitea ohne Schrägstrich am Ende | `http://192.168.10.20:3000` |
| `GITEA_REPO` | `/opt/it-wiki/.env` | Besitzer/Repository | `it-team/it-wiki` |
| `OAUTH_CLIENT_ID` | `/opt/it-wiki/.env` | Client-ID der OAuth-Anwendung | `a1b2c3d4-…` |
| `GITEA_DEPLOY_TOKEN` | `/opt/it-wiki/.env` | Token von `wiki-deploy` mit Scope `read:repository` | wird erzeugt |
| `GITEA__security__SECRET_KEY`, `INTERNAL_TOKEN`, `GITEA__oauth2__JWT_SECRET` | `/opt/gitea/.env` | interne Gitea-Schlüssel | werden erzeugt |

Die Platzhalter in `admin/config.yml` (`__WIKI_URL__`, `__GITEA_URL__`, `__GITEA_REPO__`, `__OAUTH_CLIENT_ID__`) werden beim Veröffentlichen automatisch aus `.env` ersetzt. Im Git-Repository stehen deshalb keine serverspezifischen Werte und keine Geheimnisse. Beide `.env`-Dateien haben die Rechte `600` und stehen in `.gitignore`.

Wenn sich die Server-IP ändert, müssen Sie beide `.env`-Dateien und die Weiterleitungs-URI der OAuth-Anwendung anpassen. Danach `docker compose up -d` in beiden Ordnern ausführen und mit `deploy.py --force` neu bauen.

## Decap CMS bedienen

1. `http://SERVER-IP:8080/admin/` öffnen und „Mit Gitea einloggen“ klicken.
2. Beim ersten Mal fragt Gitea, ob „Decap CMS (IT-Wiki)“ auf das Konto zugreifen darf. Mit „Anwendung autorisieren“ bestätigen.
3. Links stehen die Bereiche Anleitungen, Troubleshooting, Runbooks, Standards/Richtlinien und Weitere Inhaltstypen sowie die Einstellungen für Kategorien und Inhaltstypen. Es werden nur Beiträge angezeigt, die mit dem Editor erstellt wurden.
4. Rechts zeigt die Vorschau ungefähr, wie die Seite im Wiki aussieht.
5. „Veröffentlichen“ → „Jetzt veröffentlichen“ speichert sofort in Gitea. Nach etwa 30 bis 60 Sekunden ist die Seite im Wiki. Den Fortschritt zeigt `/admin/build/`.

Abmelden: Profilbild oben rechts → „Abmelden“. Die Anmeldung bleibt im Browser gespeichert, bis Sie sich abmelden. An gemeinsam genutzten PCs deshalb immer abmelden.

### Neue Anleitung erstellen

1. „Anleitungen“ → „+ Anleitung“ öffnen.
2. Den Titel kurz und eindeutig formulieren, zum Beispiel „DNS-Forwarder einrichten“. Daraus entsteht beim ersten Speichern der Dateiname `docs/anleitungen/dns-forwarder-einrichten.md`. Umlaute werden umgeschrieben, Leerzeichen werden zu Bindestrichen. Gibt es den Namen schon, hängt Decap `-1` an.
3. Die Kategorie wählen und eine Kurzbeschreibung in ein bis zwei Sätzen schreiben.
4. „Voraussetzungen“, „Anleitung“, „Prüfung/Erfolgskontrolle“ und „Troubleshooting“ im Texteditor ausfüllen. Er bietet fett, kursiv, Überschrift, Listen, Links und Zitate. Befehle fügen Sie über „+“ → „Code Block“ ein.
5. „Verwandte Artikel“ aus der Liste auswählen. Externe Links tragen Sie unter „Weitere Links“ ein.
6. „Verantwortlich“ leer lassen, dann wird Ihr Name eingetragen. Besser ist eine Rolle wie „IT-Team Server“.
7. „Veröffentlichen“ klicken.

Die Seite erscheint automatisch in der Navigation unter „Anleitungen“ und in der Tabelle auf der Übersichtsseite. Troubleshooting-Artikel, Runbooks und Standards landen in ihren bestehenden Bereichen. `mkdocs.yml` muss dafür niemand bearbeiten.

### Kategorien anlegen

1. In der Redaktion links „Einstellungen: Kategorien“ → „+ Kategorie“ öffnen.
2. Den Namen eintragen, zum Beispiel „Drucker & Scanner“. Eine Beschreibung und die Reihenfolge sind optional, eine kleinere Zahl steht in der Navigation weiter oben.
3. „Veröffentlichen“ → „Jetzt veröffentlichen“.

Die Kategorie steht sofort in allen Formularen im Feld „Kategorie“ zur Auswahl. Im Wiki gruppiert sie die Anleitungen und die Beiträge eigener Inhaltstypen in der Navigation, zum Beispiel „Anleitungen → Drucker & Scanner → …“. Außerdem erscheint sie als Schlagwort (Tag).

Zum Umbenennen ändern Sie den Namen in der Kategorie. Bestehende Beiträge behalten den alten Namen, bis Sie sie öffnen, die neue Kategorie wählen und speichern. Eine Kategorie zu löschen ist unkritisch: Beiträge mit diesem Namen bleiben erhalten und werden weiter unter dem alten Namen gruppiert.

Gespeichert werden Kategorien als kleine Dateien unter `cms/kategorien/`, also außerhalb der Wiki-Seiten.

### Neue Inhaltstypen anlegen

Für Inhalte, die weder Anleitung noch Troubleshooting, Runbook oder Standard sind, zum Beispiel Checklisten oder Kundendokumentationen:

1. „Einstellungen: Inhaltstypen“ → „+ Inhaltstyp“ öffnen.
2. Den Namen in Einzahl („Kundendokumentation“) und in Mehrzahl für die Navigation („Kundendokumentationen“) eintragen. Optional kommen eine Beschreibung für die Übersichtsseite und die Position in der Navigation dazu („Nach den Anleitungen“ oder „Am Ende“).
3. Veröffentlichen.
4. Beiträge legen Sie unter „Weitere Inhaltstypen“ → „+ Beitrag“ an. Dort wählen Sie Inhaltstyp und Kategorie, Titel, Inhalt (gegliedert mit den Überschriften-Knöpfen H2/H3), optionale Steckbrief-Angaben (zum Beispiel Kunde: Müller, Intervall: monatlich), Bilder und verwandte Artikel.

Sobald es den ersten Beitrag eines Inhaltstyps gibt, erscheint im Wiki ein eigener Navigationsbereich mit diesem Namen. Er enthält eine automatisch erzeugte Übersichtsseite mit allen Beiträgen dieses Typs. Die Beiträge liegen unter `docs/inhalte/` und haben Adressen wie `/inhalte/<dateiname>/`.

Alle eigenen Inhaltstypen nutzen dasselbe flexible Formular. Wer für einen Typ feste Formularfelder braucht, wie sie Anleitung oder Runbook haben, muss `admin/config.yml` und `hooks/wiki_cms.py` von einem Administrator erweitern lassen. Ein Beispieltyp „Checkliste“ ist bereits angelegt.

### Bild hochladen

- Im Feld „Screenshots/Bilder“ auf „bild hinzufügen“ → „Wähle ein Bild“ → „Hochladen“ klicken, die Datei auswählen und mit „Ausgewähltes Element verwenden“ übernehmen. Dann eine Bildunterschrift eintragen.
- Alternativ fügen Sie das Bild im Texteditor über „+“ → „Image“ direkt an der passenden Stelle im Text ein.
- Gespeichert wird unter `docs/assets/images/uploads/`. Den Dateinamen bitte vorher sprechend und ohne Umlaute wählen, zum Beispiel `dns-forwarder-weiterleitung.png`. Gleichnamige Dateien würden das vorhandene Bild ersetzen.
- Vor dem Hochladen Passwörter, Lizenzschlüssel, E-Mail-Adressen und Namen schwärzen.
- Empfohlen sind PNG oder JPG unter 1 MB.

### Artikel ändern

- Den Artikel in der Liste öffnen, ändern und auf „Veröffentlichen“ klicken. Der Dateiname bleibt gleich, auch wenn sich der Titel ändert.
- „Zuletzt geprüft“ bei jeder fachlichen Prüfung aktualisieren.
- Von Hand angelegte Seiten (ohne Formular) und die Übersichtsseiten erscheinen nicht im Editor. Sie enthalten Tabellen und Hinweisboxen, die der einfache Texteditor nicht verlustfrei bearbeiten kann. Diese Seiten bearbeiten Sie direkt in Gitea: Repository → Datei öffnen → Stift-Symbol → „Änderungen committen“. Danach wird ebenfalls automatisch gebaut.
- Eine frühere Version wiederherstellen: In Gitea die Datei öffnen, „Verlauf“ wählen, den gewünschten Commit öffnen und den Inhalt übernehmen. Administratoren können auf dem Server auch `git revert <commit>` ausführen und pushen.

### Löschen oder archivieren

- Archivieren ist der Normalfall. Im Artikel „Archiviert“ einschalten und veröffentlichen. Die Seite bleibt erreichbar, zeigt oben einen Hinweis „Archiviert“ und ist in den Listen markiert.
- Löschen ist im Editor bewusst abgeschaltet. Administratoren löschen in Gitea: Datei öffnen → Papierkorb-Symbol → committen. Vorher bitte prüfen, ob andere Artikel auf die Seite verlinken. Sonst schlägt der nächste Build fehl, und die Live-Seite bleibt auf dem alten Stand, bis der Link entfernt ist.

## Build und Deploy

| Schritt | Detail |
|---|---|
| Erkennen | `git ls-remote` alle `POLL_INTERVAL` Sekunden (Standard 30) mit Lese-Token |
| Export | `git fetch` + `git archive` des exakten Commits in ein temporäres Verzeichnis |
| Build | `mkdocs build --strict` nach `/srv/site/releases/<zeit>-<commit>.partial` (Zeitlimit 600 s) |
| Prüfen | Exit-Code 0 und `index.html` vorhanden |
| Ergänzen | `admin/` hineinkopieren, Platzhalter ersetzen, `decap-cms.js` hinzufügen |
| Umschalten | Symlink `/srv/site/current` per `rename()` atomar umstellen; Leser sehen nie einen halben Stand |
| Aufräumen | die letzten 10 Releases bleiben erhalten (`KEEP_RELEASES`) |
| Status | `/admin/build/` mit Verlauf und Protokoll je Build |

Ein fehlgeschlagener Commit wird nicht immer wieder gebaut. Der Dienst wartet auf den nächsten Commit, der den Fehler behebt.

```bash
cd /opt/it-wiki
docker compose exec deployer /usr/local/bin/deploy.py --list                 # Releases (* = live)
docker compose exec deployer /usr/local/bin/deploy.py --rollback 20261001-101500-ab12cd34ef
docker compose exec deployer /usr/local/bin/deploy.py --force                # aktuellen Stand neu bauen
```

Ein Rollback schaltet sofort auf ein älteres Release zurück. Er gilt, bis der nächste neue Commit veröffentlicht wird. Für eine dauerhafte Rücknahme den Commit in Gitea zurücknehmen.

Optional zeigt Gitea grüne bzw. rote Haken am Commit. Dafür in `.env` `GITEA_COMMIT_STATUS=true` setzen, dem Benutzer `wiki-deploy` Schreibrecht geben und ein neues Token mit `write:repository` eintragen. Standardmäßig bleibt der Dienst bei reinem Lesezugriff.

## Fehlerdiagnose

| Symptom | Ursache und Lösung |
|---|---|
| `/admin/` zeigt „Fehler beim Laden der Konfiguration“ | `admin/config.yml` fehlerhaft oder Platzhalter nicht ersetzt. Prüfen mit `curl http://127.0.0.1:8080/admin/config.yml`, `.env` kontrollieren, `deploy.py --force` |
| Nach „Mit Gitea einloggen“ meldet Gitea „invalid redirect_uri“ | Die Weiterleitungs-URI der OAuth-Anwendung weicht von der Adresse im Browser ab (IP oder Name, Port, `/admin/`) |
| Anmeldung klappt, dann „Failed to fetch“ oder CORS-Fehler (F12 → Konsole) | `WIKI_URL` in `/opt/gitea/.env` stimmt nicht exakt mit der Browser-Adresse überein. Anpassen, dann `cd /opt/gitea && docker compose up -d` |
| „Your Gitea user account does not have access to this repo“ | Benutzer ist nicht im Team „Redaktion“ |
| Speichern geht, Seite erscheint nicht | `/admin/build/` öffnen. Bei „fehlgeschlagen“ das Protokoll lesen, meist ist es ein defekter Link. Den Artikel korrigieren und erneut veröffentlichen |
| Build-Status zeigt nichts Neues | `docker compose logs --tail 50 deployer`. Typisch sind ein abgelaufenes oder falsches Token oder ein Gitea, das nicht erreichbar ist (Netzwerk `gitea-net`) |
| Wiki zeigt 404 auf `/` | Es gibt noch kein Release: `docker compose exec deployer /usr/local/bin/deploy.py --force` |
| Gitea startet nicht | `cd /opt/gitea && docker compose logs gitea`. Häufig sind die Rechte falsch: `sudo chown -R 1000:1000 /opt/gitea/data /opt/gitea/config` |

Build lokal nachstellen, ohne etwas zu veröffentlichen:

```bash
cd /opt/it-wiki && git pull
docker run --rm -v "$PWD":/src:ro it-wiki-deployer sh -c 'cp -r /src /tmp/w && cd /tmp/w && mkdocs build --strict -d /tmp/site'
```

Wichtig für Administratoren: Der Ordner `/opt/it-wiki` ist eine Arbeitskopie. Redakteure schreiben direkt nach Gitea. Vor eigenen Änderungen auf dem Server deshalb immer zuerst `git pull` ausführen, danach committen und pushen.

## Zugriff über Domains (Reverse Proxy)

Wiki und Gitea können hinter einem Reverse Proxy mit HTTPS laufen, zum Beispiel hinter dem Nginx Proxy Manager (NPM). Die Redaktion braucht keinen eigenen Eintrag, sie ist der Pfad `/admin/` des Wikis.

| Proxy-Host | Ziel | Hinweis |
|---|---|---|
| `wiki.firma.de` | `http://SERVER-IP:8080` | Wiki, Redaktion und Build-Status |
| `git.firma.de` | `http://SERVER-IP:3000` | Gitea. Unter „Advanced“ `client_max_body_size 50m;` eintragen, damit größere Bilder hochgeladen werden können |

Beide Hosts brauchen HTTPS. Läuft das Wiki über HTTPS und Gitea über HTTP, blockiert der Browser die Anmeldung, und das Skript lehnt diese Kombination ab.

Für Domains, die nur im lokalen Netz erreichbar sind, stellen Sie das Zertifikat per DNS-Challenge aus:
1. In NPM „Use a DNS Challenge“ wählen und als Anbieter zum Beispiel Cloudflare.
2. Einen API-Token mit der Vorlage „Edit zone DNS“ für die Zone anlegen und eintragen.
3. Ein Wildcard-Zertifikat `*.firma.de` deckt beide Hosts ab.

Im internen DNS zeigen beide Namen auf die IP des Reverse Proxy.

Für ein internes Wiki sollte der Wiki-Host nicht aus dem Internet erreichbar sein, oder er wird in NPM per Access List eingeschränkt. Lesen braucht keine Anmeldung, Gitea verlangt dagegen immer eine.

### Adressen ändern (IP ↔ Domains)

```bash
sudo bash /opt/it-wiki/scripts/cms-install.sh adressen
```

Das Skript fragt die neuen Adressen ab und legt zuerst ein Backup an. Danach erledigt es diese Schritte:
1. Es passt `/opt/it-wiki/.env` und `/opt/gitea/.env` an und sichert die alten Dateien als `*.bak-…`.
2. Es setzt `DECAP_HTTP_LOGIN` passend (`false` bei HTTPS).
3. Es startet Gitea neu und ergänzt in der OAuth-Anwendung die neue Weiterleitung `…/admin/`. Die alte bleibt erhalten.
4. Es baut das Wiki neu, damit die Redaktion und die Knöpfe „Redaktion“ und „Git“ die neuen Adressen verwenden.

Danach melden Sie sich in der Redaktion einmal unter der neuen Adresse an.

Für die OAuth-Anwendung muss der Admin angegeben werden, der sie bei der Installation angelegt hat. Bei einem anderen Benutzer meldet das Skript eine Warnung. Dann ergänzen Sie die Weiterleitung von Hand in Gitea unter „Einstellungen“ → „Anwendungen“ → „Decap CMS (IT-Wiki)“.

## Knöpfe „Redaktion“ und „Git“ in der Kopfzeile

Oben links im Wiki stehen zwei Knöpfe. „Redaktion“ öffnet `/admin/`, „Git“ öffnet das Repository in Gitea in einem neuen Tab. Auf schmalen Bildschirmen werden nur die Symbole angezeigt. Die Adressen kommen beim Build aus `GITEA_URL` und `GITEA_REPO` in `/opt/it-wiki/.env` (Block `extra: cms_links` in `mkdocs.yml`). Fehlt `GITEA_URL`, etwa beim reinen Wiki-Container ohne CMS, werden die Knöpfe nicht angezeigt. Leser ohne Gitea-Konto sehen die Knöpfe auch, landen aber auf der Anmeldeseite.

## Update auf eine neue Paketversion

Inhalte aus der Redaktion bleiben bei einem Update erhalten. Das Skript holt zuerst den aktuellen Stand aus Gitea und ersetzt dann nur die Programmdateien (`admin/`, `hooks/`, `overrides/main.html`, `scripts/` und die Dokumentation im Hauptordner). Kategorien und Inhaltstypen ergänzt es nur, wenn sie fehlen. 

```bash
# neue Version in einen eigenen Ordner holen (hier darf der Klon flach sein)
rm -rf ~/it-wiki-neu && git clone --depth 1 https://github.com/ben101111/it-wiki.git ~/it-wiki-neu
sudo bash ~/it-wiki-neu/scripts/cms-install.sh update
```

Das Skript legt zuerst ein Backup an, fragt nach dem Gitea-Admin-Zugang und führt einen Testbuild aus. Erst wenn der klappt, committet und pusht es. Nach etwa einer Minute ist die neue Version online. Die Redaktion danach mit Strg+F5 neu laden.

## Update-Anleitung (Gitea, Decap CMS, MkDocs)

Vor jedem Update: `sudo bash /opt/it-wiki/scripts/cms-install.sh backup`

Gitea (nur innerhalb derselben Hauptversion ohne Weiteres, vorher die Release Notes lesen):

```bash
cd /opt/gitea
sed -i 's#gitea/gitea:1.27.3-rootless#gitea/gitea:1.27.4-rootless#' docker-compose.yml
docker compose pull && docker compose up -d && docker compose logs --tail 30 gitea
```

Decap CMS:

```bash
# neue Version und Prüfsumme ermitteln
curl -fsSL https://unpkg.com/decap-cms@3.16.4/dist/decap-cms.js | sha256sum
# in docker/deployer/Dockerfile DECAP_VERSION und DECAP_SHA256 anpassen, dann:
cd /opt/it-wiki && docker compose build deployer && docker compose up -d deployer
docker compose exec deployer /usr/local/bin/deploy.py --force
```

MkDocs, Material und Plugins:

```bash
cd /opt/it-wiki && git pull
# Versionen in requirements.txt erhöhen
docker compose build deployer      # Testbuild siehe Fehlerdiagnose
git commit -am "MkDocs-Pakete aktualisiert" && git push
docker compose up -d deployer
```

nginx: `docker compose pull it-wiki && docker compose up -d it-wiki`

Bei Problemen die alte Versionsnummer wieder eintragen und den Befehl wiederholen. Inhalte und Releases bleiben erhalten.

## Deinstallation

```bash
sudo bash /opt/it-wiki/scripts/cms-install.sh uninstall
```

Das Skript zeigt zuerst an, was entfernt wird, und fragt, ob auch die Docker-Images und die Backups gelöscht werden sollen. Zum Bestätigen tippen Sie `ENTFERNEN` ein. Bei jeder anderen Eingabe passiert nichts.

Danach geht es so vor:
1. Es legt ein letztes Vollbackup nach `/opt/backups` an.
2. Es stoppt und entfernt die Container `it-wiki`, `it-wiki-deployer` und `gitea`, ihre Volumes, das Netzwerk `gitea-net` und das Image `it-wiki-deployer`.
3. Es löscht `/opt/it-wiki` und `/opt/gitea`, also alle Inhalte, Gitea-Benutzer und Secrets, und entfernt den Backup-Eintrag aus der root-Crontab.
4. Nur wenn Sie es gewählt haben, löscht es auch die Images `nginx`, `gitea` und `python` sowie alle Backups.

Docker selbst bleibt installiert. Aus dem zuletzt erstellten Backup lässt sich alles wiederherstellen, siehe „Restore“. Proxy-Hosts im Reverse Proxy und DNS-Einträge entfernen Sie von Hand.

## Sicherheit und Grenzen

Umgesetzt:

- Leser brauchen keine Anmeldung. Schreiben ist nur mit Gitea-Konto und Schreibrecht auf das Repository möglich, und Gitea prüft jeden Schreibzugriff serverseitig.
- `/admin/` ist eine statische Seite ohne eigene Rechte. Anonyme Besucher sehen nur den Anmeldeknopf. Die Gitea-API verweigert ihnen jeden Zugriff, da das Repository privat ist und `REQUIRE_SIGNIN_VIEW` gilt.
- Keine öffentliche Registrierung. Starke Passwörter sind vorgeschrieben, Zwei-Faktor-Anmeldung ist möglich.
- Im Git-Repository stehen keine Geheimnisse. Token und Schlüssel liegen nur in `.env` (Rechte 600).
- Der Deploy-Dienst läuft ohne Root, mit schreibgeschütztem Dateisystem und `cap_drop: ALL`. Er hat keinen Docker-Socket und keinen eingehenden Port. Er führt keine Befehle aus dem Netz aus, nur den festen Befehl `mkdocs build --strict`.
- Jede Änderung ist ein Commit mit Autor und lässt sich rückgängig machen. Fehlerhafte Builds werden nie veröffentlicht.

Grenzen:

- Ohne HTTPS laufen Gitea-Passwörter und Zugriffstoken unverschlüsselt durch das LAN. Das gilt schon für die normale Gitea-Anmeldung über `http://SERVER-IP:3000`.
- Decap CMS lässt die Anmeldung von sich aus nur über HTTPS zu. Damit die geforderte Adresse `http://SERVER-IP:8080/admin/` funktioniert, entfernt der Deploy-Dienst beim Veröffentlichen genau diese eine Prüfung aus `decap-cms.js` (Schalter `DECAP_HTTP_LOGIN=true` in `.env`). Außerdem rüstet `admin/index.html` die Browser-Funktionen SHA-256 und `randomUUID` nach, die Browser nur bei HTTPS bereitstellen. Die Original-Datei wird beim Image-Build per SHA-256 geprüft.
- Dringend empfohlen ist deshalb ein interner Reverse-Proxy mit Zertifikat, zum Beispiel aus der eigenen AD-Zertifizierungsstelle, für Wiki und Gitea. Danach `WIKI_URL` und `GITEA_URL` auf `https://` umstellen, die OAuth-Weiterleitungs-URI anpassen und `DECAP_HTTP_LOGIN=false` setzen. Beide Adressen müssen dann HTTPS nutzen, weil Browser gemischte Inhalte blockieren.
- Decap CMS bietet mit Gitea keinen Freigabe-Workflow (Entwurf, Prüfung, Freigabe). „Veröffentlichen“ geht direkt live. Wer eine Vier-Augen-Prüfung braucht, muss sie außerhalb des Editors über Gitea-Branches und Pull Requests abbilden.
- Jeder Redakteur braucht Schreibrecht auf das ganze Repository. Theoretisch kann er über die Gitea-Oberfläche oder API also auch andere Dateien ändern. Das ist nachvollziehbar und rückgängig zu machen, aber nicht technisch verhindert.
- Gleichnamige Bild-Uploads überschreiben vorhandene Bilder. Git LFS wird von Decap mit Gitea nicht unterstützt, daher bitte keine großen Dateien hochladen.
- Bestehende komplexe Seiten werden in Gitea bearbeitet, nicht im Editor (siehe „Artikel ändern“).
- Der Build-Status unter `/admin/build/` ist ohne Anmeldung lesbar. Er enthält Commit-Titel, Autorennamen und Build-Meldungen, aber keine Inhalte und keine Geheimnisse. Wer das nicht möchte, schützt `location /admin/build/` in `docker/default.conf.template` mit `auth_basic`.
- Die Anmeldung über Active Directory ist möglich (Gitea: Website-Administration → Authentifizierungsquellen → LDAP), gehört aber nicht zum Umfang dieser Einrichtung.

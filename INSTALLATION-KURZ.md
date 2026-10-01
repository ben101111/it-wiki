# IT-Wiki – Kurzanleitung Installation

Wiki (MkDocs) + Redaktion im Browser (Decap CMS) + Gitea, alles in Docker auf einer Debian-VM.

## Voraussetzungen

- Debian 12 oder 13, feste IP, 2 GB RAM, 10 GB frei
- Internetzugang während der Installation
- Ports 8080 (Wiki) und 3000 (Gitea) frei
- Optional: Nginx Proxy Manager (NPM) und zwei Domains, z. B. `wiki.firma.de` und `git.firma.de`

## 1. Repository klonen

```bash
sudo apt update && sudo apt install -y git
sudo git clone https://github.com/ben101111/it-wiki.git /opt/it-wiki
cd /opt/it-wiki
```

Bitte vollständig klonen (ohne `--depth`), weil das Repository später ins lokale Gitea übertragen wird. Ohne Git geht es auch: ZIP über „Code → Download ZIP“ herunterladen, entpacken und den Ordner nach `/opt/it-wiki` verschieben.

## 2. Docker und Hilfsprogramme

```bash
sudo bash scripts/cms-install.sh docker
```

Das installiert Docker, git, jq und curl, falls sie fehlen.

## 3. Installieren

```bash
sudo bash scripts/cms-install.sh install
```

Das Skript fragt Folgendes ab:

1. **Server-IP:** mit `j` bestätigen. Ist sie falsch: `sudo SERVER_IP=192.168.10.20 bash scripts/cms-install.sh install`, ohne spitze Klammern.
2. **Zugriff:**
   - `1` = über die IP (`http://IP:8080`, `http://IP:3000`)
   - `2` = über Domains, z. B. `wiki.firma.de` und `git.firma.de`. Das Skript setzt selbst `https://` davor.
3. **Beispiele:** `J` = mit sechs Beispielbeiträgen, `n` = Wiki startet komplett leer.
4. **Erster Gitea-Admin:** Benutzername, E-Mail und Passwort, mindestens 12 Zeichen mit Groß- und Kleinbuchstaben und Ziffer.

Am Ende zeigt das Skript die Adressen und die Testergebnisse an.

## 4. Reverse Proxy (nur bei Domains)

Im NPM zwei Proxy-Hosts anlegen, beide mit SSL-Zertifikat und „Force SSL“:

| Domain | Weiterleiten an |
|---|---|
| `wiki.firma.de` | `http://IP:8080` |
| `git.firma.de` | `http://IP:3000`, unter „Advanced“: `client_max_body_size 50m;` |

- Die Redaktion braucht keinen eigenen Eintrag, sie läuft unter `wiki.firma.de/admin/`.
- Nur im lokalen Netz: das Zertifikat per DNS-Challenge ausstellen (Cloudflare-Token „Edit zone DNS“, Wildcard `*.firma.de`).
- Im internen DNS beide Namen auf die IP des NPM zeigen lassen.

## 5. Redakteure anlegen

```bash
sudo bash /opt/it-wiki/scripts/cms-install.sh editor vorname.nachname name@firma.de
```

Das Skript erzeugt ein Startpasswort. Der Redakteur muss es bei der ersten Anmeldung in Gitea ändern.

## Beispielinhalte entfernen

Wenn Sie mit Beispielen installiert haben (Titel beginnt mit „Beispiel:“), entfernen Sie später alle auf einmal:

```bash
sudo bash /opt/it-wiki/scripts/cms-install.sh beispiele
```

Die Startseite `docs/index.md` passen Sie in Gitea an (Datei öffnen, Stift-Symbol).

## Täglich benutzen

| Was | Wo |
|---|---|
| Wiki lesen | `https://wiki.firma.de/` (oder `http://IP:8080/`) |
| Beiträge schreiben und ändern | Knopf „Redaktion“ oben links bzw. `/admin/` |
| Kategorien und Inhaltstypen anlegen | in der Redaktion unter „Einstellungen“ |
| Prüfen, ob ein Beitrag online ist | `/admin/build/`, nach 30–60 Sekunden „erfolgreich“ |
| Löschen, Verlauf, Rückgängig machen | Knopf „Git“ oben links (Gitea) |

## Nützliche Befehle

```bash
cd /opt/it-wiki
sudo bash scripts/cms-install.sh status     # Zustand anzeigen
sudo bash scripts/cms-install.sh test       # Selbsttest
sudo bash scripts/cms-install.sh backup     # Backup nach /opt/backups
sudo bash scripts/cms-install.sh adressen   # IP <-> Domains umstellen
sudo docker compose logs --tail 30 deployer # Build-Protokoll
sudo docker compose exec deployer /usr/local/bin/deploy.py --force   # sofort neu bauen
```

## Update auf eine neue Paketversion

```bash
rm -rf ~/it-wiki-neu && git clone --depth 1 https://github.com/ben101111/it-wiki.git ~/it-wiki-neu
sudo bash ~/it-wiki-neu/scripts/cms-install.sh update
```

Die Beiträge aus der Redaktion bleiben dabei erhalten.

## Alles entfernen

```bash
sudo bash /opt/it-wiki/scripts/cms-install.sh uninstall
```

Vorher legt das Skript automatisch ein Backup an. Es fragt, ob auch Images und Backups gelöscht werden sollen. Zur Bestätigung tippen Sie `ENTFERNEN` ein. Docker selbst bleibt installiert.

## Häufige Fehler

| Meldung | Lösung |
|---|---|
| `Permission denied` beim Hochladen per WinSCP | ins Home-Verzeichnis hochladen, dann mit `sudo mv` nach `/opt` verschieben |
| `Programm 'jq' fehlt` | `sudo apt install -y jq git curl` |
| `<IP>: Datei oder Verzeichnis nicht gefunden` | die IP ohne `< >` eingeben |
| Knopf „Git“ öffnet die IP statt der Domain | `sudo bash scripts/cms-install.sh adressen` |
| Build „fehlgeschlagen“ | unter `/admin/build/` das Protokoll öffnen, meist ein kaputter Link; Beitrag korrigieren |

Ausführliche Anleitung: [HANDBUCH.md](HANDBUCH.md)

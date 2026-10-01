# Mitwirken

Beiträge sind willkommen: Fehlerberichte, Verbesserungsvorschläge und Pull Requests.

## Fehler melden

Bitte im Issue angeben:
- Debian-Version, `docker --version`
- den verwendeten Befehl und die letzten Zeilen der Ausgabe
- bei Build-Fehlern: das Protokoll aus `/admin/build/`

Bitte **keine** `.env`-Dateien, Tokens, Passwörter oder internen Wiki-Inhalte anhängen.

## Lokal testen

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
mkdocs serve          # Vorschau unter http://127.0.0.1:8000
mkdocs build --strict # muss ohne Warnung durchlaufen
bash -n scripts/cms-install.sh
```

## Pull Requests

- Ein Thema pro Pull Request
- Oberfläche und Dokumentation sind auf Deutsch
- Dateinamen: Kleinbuchstaben, Bindestriche, keine Umlaute
- Änderungen am Verhalten bitte in `CHANGELOG.md` und `HANDBUCH.md` nachtragen

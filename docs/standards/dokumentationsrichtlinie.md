---
title: "Dokumentationsrichtlinie"
tags:
  - Standard
  - Wiki
---

# Dokumentationsrichtlinie

Regeln, damit das Wiki einheitlich, auffindbar und sicher bleibt.

## Welcher Inhaltstyp?

| Inhaltstyp | Wofür | Beispiel |
|---|---|---|
| Anleitung | einmalige Einrichtung, Installation, Konfiguration | „Netzlaufwerk per GPO verbinden“ |
| Troubleshooting | ein konkretes Fehlerbild mit Lösung | „Outlook fragt ständig nach dem Kennwort“ |
| Runbook | wiederkehrender oder kritischer Ablauf mit Rollback | „Monatlicher Patchday“ |
| Standard | verbindliche Festlegung | „Namenskonvention für Server“ |
| eigener Inhaltstyp | alles andere, z. B. Checklisten | „Checkliste neue Mitarbeitende“ |

Eigene Inhaltstypen und Kategorien legen Sie in der Redaktion unter „Einstellungen“ an.

## Titel und Dateinamen

- Titel beschreiben das Ergebnis oder das Fehlerbild: „DNS-Weiterleitung einrichten“, nicht „DNS“.
- Bei Fehlern gehört die Fehlermeldung oder der Fehlercode in den Titel.
- Dateinamen erzeugt die Redaktion automatisch aus dem Titel: Kleinbuchstaben, Bindestriche, keine Umlaute.

## Inhalt

- Ein Beitrag behandelt genau ein Thema.
- Schritte nummerieren, Befehle als Codeblock, Platzhalter in `GROSSBUCHSTABEN` (z. B. `SERVERNAME`).
- Screenshots nur, wenn sie wirklich helfen; Text in Bildern ist nicht durchsuchbar.
- Jede Anleitung endet mit einer Prüfung, woran man den Erfolg erkennt.
- Verwandte Artikel verlinken (Feld „Verwandte Artikel“).

## Sicherheit

- **Keine** Passwörter, Lizenzschlüssel, Tokens, privaten Schlüssel oder Zertifikate im Wiki – Verweis auf den Passwortmanager genügt.
- Keine personenbezogenen Daten (Namen, private Telefonnummern) außer der verantwortlichen Person.
- Screenshots vor dem Hochladen auf sichtbare Kennwörter, Seriennummern und Kundendaten prüfen.

## Pflege

- „Zuletzt geprüft“ beim Überarbeiten aktualisieren.
- Veraltete Beiträge nicht löschen, sondern in der Redaktion als **Archiviert** markieren.
- Löschen und Wiederherstellen erledigt ein Administrator in Gitea (vollständiger Verlauf).

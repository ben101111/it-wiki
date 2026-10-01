---
vorlage: standard
dateiname: beispiel-namenskonvention-server
title: "Beispiel: Namenskonvention für Server"
kategorie: Windows Server
geltungsbereich: Alle neuen Server und virtuellen Maschinen
ziel: |-
  Servernamen sollen Standort, Funktion und laufende Nummer erkennen lassen.
verantwortlich: IT-Team
gueltig_ab: 2026-01-01
zuletzt_geprueft: 2026-01-01
tags:
  - Beispiel
archiviert: false
---

Aufbau: `STANDORT-FUNKTION-NR`

| Teil | Werte | Beispiel |
|---|---|---|
| Standort | 3 Buchstaben | `BER` |
| Funktion | `DC`, `FS`, `RDS`, `APP`, `SQL`, `BKP` | `FS` |
| Nummer | zweistellig | `01` |

Beispiel: `BER-FS-01` ist der erste Dateiserver am Standort Berlin.

- Maximal 15 Zeichen (NetBIOS-Grenze).
- Nur Großbuchstaben, Ziffern und Bindestriche.

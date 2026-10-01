---
vorlage: anleitung
dateiname: beispiel-automatische-sicherheitsupdates-debian
title: "Beispiel: Automatische Sicherheitsupdates unter Debian aktivieren"
kategorie: Linux
beschreibung: Sicherheitsupdates auf Debian-Servern automatisch installieren lassen. Dies ist ein Beispielbeitrag der Vorlage.
voraussetzungen: |-
  - Debian 12 oder 13
  - Zugang mit `sudo`-Rechten
pruefung: |-
  ```bash
  sudo unattended-upgrade --dry-run --debug | tail -20
  systemctl status apt-daily-upgrade.timer
  ```

  Der Testlauf zeigt die erlaubten Quellen, der Timer ist `active`.
verantwortlich: IT-Team
zuletzt_geprueft: 2026-01-01
tags:
  - Beispiel
  - Debian
archiviert: false
---

1. Paket installieren:

    ```bash
    sudo apt update
    sudo apt install -y unattended-upgrades apt-listchanges
    ```

2. Automatische Updates aktivieren:

    ```bash
    sudo dpkg-reconfigure -plow unattended-upgrades
    ```

    Die Frage mit **Ja** beantworten.

3. Optional in `/etc/apt/apt.conf.d/50unattended-upgrades` einen automatischen Neustart zu einer festen Uhrzeit erlauben:

    ```text
    Unattended-Upgrade::Automatic-Reboot "true";
    Unattended-Upgrade::Automatic-Reboot-Time "03:30";
    ```

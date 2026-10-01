# Sicherheit

## Lücken melden

Bitte melden Sie Sicherheitslücken **nicht** als öffentliches Issue, sondern über „Security → Report a vulnerability“ (private Meldung) in diesem Repository. Beschreiben Sie das Problem, die betroffene Version und wie es sich nachvollziehen lässt.

## Hinweise für den Betrieb

- Das Wiki ist für interne Netze gedacht. Lesen braucht keine Anmeldung.
- `.env`-Dateien enthalten Tokens und Secrets und gehören nie in ein Git-Repository.
- Gitea, Docker und das Betriebssystem regelmäßig aktualisieren.
- Für den Dauerbetrieb HTTPS über einen Reverse Proxy verwenden.

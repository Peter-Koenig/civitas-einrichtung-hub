# p2d2 – Demo-Accounts (CIVITAS/CORE-AddOn)

Diese Datei steuert die Demo-Accounts der Keycloak-Provisionierung (`addon_25_iam.sh`). Das Skript liest nur den YAML-Block. Text außerhalb ist Kommentar.

- Datei vorhanden: die Accounts im YAML-Block werden angelegt bzw. ergänzt.
- Datei fehlt (gelöscht oder umbenannt): es werden keine Demo-Accounts angelegt.
- Bereits vorhandene Accounts werden dadurch nicht gelöscht.
- Kennwörter stehen nicht in dieser Datei. Sie kommen aus der Umgebungsvariable `P2D2_DEMO_PASSWORD`.

Begriffe: `roles` steuern Rechte. `memberships` sind fachliche Zuordnungen (berufliche Kommune oder Community). `home_region_key` ist eine persönliche Startregion (Präferenz, kein Recht). Alle Personen und Adressen sind fiktiv.

```yaml
version: 1
accounts:
  - username: hans
    email: hans.muster@nospam.scanea.de
    first_name: Hans
    last_name: Meier
    roles: [editor, verwaltung]
    home_region_key: de-Hamburg
    memberships:
      - { type: kommune, key: hamburg, role: verwaltung, wp_name: de-Hamburg }

  - username: jule
    email: jule.kovalenko@nospam.scanea.de
    first_name: Jule
    last_name: Kovalenko
    roles: [verwaltung, osm]
    home_region_key: de-Bonn
    memberships:
      - { type: kommune, key: koeln, role: verwaltung, wp_name: "de-Köln" }
      - { type: community, key: osm, role: osm }

  - username: Chisom
    email: chisom.eze@nospam.scanea.de
    first_name: Chisom
    last_name: Eze
    roles: [verwaltung]
    home_region_key: de-Kiel
    memberships:
      - { type: kommune, key: kiel, role: verwaltung, wp_name: de-Kiel }

  - username: arman
    email: arman.ekov@nospam.scanea.de
    first_name: Arman
    last_name: Ekov
    roles: [verwaltung]
    home_region_key: de-Berlin
    memberships:
      - { type: kommune, key: berlin, role: verwaltung, wp_name: de-Berlin }

  - username: meera
    email: meera.pillai@nospam.scanea.de
    first_name: Meera
    last_name: Pillai
    roles: [osm, qs1_reviewer]
    home_region_key: de-Dortmund
    memberships:
      - { type: community, key: osm, role: osm }

  - username: valentina
    email: valentina.cruz@nospam.scanea.de
    first_name: Valentina
    last_name: Cruz
    roles: [qs2_reviewer, qs1_reviewer, osm, export_admin]
    home_region_key: de-Köln
    memberships:
      - { type: community, key: osm, role: osm }
```

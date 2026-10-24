# p2d2 – GeoServer-Metadaten

Das Konfigurationsskript liest nur den YAML-Block. Text außerhalb ist Kommentar.
Platzhalter: `{stage}` = Workspace-Name, `{stage_beschreibung}` = Eintrag aus `stages`, `{stadt}` = Ordner unter `supplement/geotiffs/`, `%ws%` = Workspace-Name im Layer-Titel.

```yaml
version: 1

workspace_settings:               # lokale Einstellungen je p2d2-Workspace
  numDecimals: 8
  charset: UTF-8
  onlineResource: "https://www.data-dna.eu"
  contact:
    contactOrganization: "p2d2 c/o Projektberatung Dr. König"
    contactPerson: "Peter König"
    contactPosition: "Project founder"
    contactEmail: "info@data-dna.eu"
    addressCity: "Bonn"
    addressCountry: "Deutschland"

service:                          # gilt für WMS und WFS je Workspace
  onlineResource: "https://doc.data-dna.eu/de/administrationshandbuch/ogc-dienste"
  maintainer: "p2d2 c/o Projektberatung Dr. König"
  fees: "NONE"
  accessConstraints: "Daten: CC0-1.0. Ausnahme Layer geo-containers: ODbL-1.0 (© OpenStreetMap-Mitwirkende, https://www.openstreetmap.org/copyright)."
  keywords: ["p2d2", "Public-Public Data-DNA", "Geodaten", "Friedhöfe"]
  wms:
    title: "p2d2 Karten – {stage}"
    abstract: "Web Map Service der Anwendung p2d2 (Public-Public Data-DNA): Friedhofsflächen, Grabfluren, Gräber und Friedhofspläne. Stufe: {stage_beschreibung}."
  wfs:
    title: "p2d2 Geodaten (WFS) – {stage}"
    abstract: "Web Feature Service der Anwendung p2d2 (Public-Public Data-DNA). Lesezugriff auf die Fachdaten, Schreibzugriff (WFS-T) nur für berechtigte Nutzer. Stufe: {stage_beschreibung}."
    featureBounding: false        # Parität zum Standalone (keine bbox je Feature)

stages:
  main: "Hauptstand"
  dev:  "Entwicklungsstand"
  de1:  "Team-Staging DE1"
  de2:  "Team-Staging DE2"
  fv:   "Team-Staging FV"

layers:
  geo-containers:
    title: "Geo-Container (%ws%)"
    abstract: "Räumliche Container (z. B. Friedhofsflächen) als Polygone mit Gemeinde und Typ. Quelle: OpenStreetMap, Lizenz: ODbL-1.0."
    keywords: ["Geo-Container", "Friedhof", "Fläche", "OpenStreetMap"]
    license: "ODbL-1.0"
    attribution: { title: "© OpenStreetMap-Mitwirkende", href: "https://www.openstreetmap.org/copyright" }
  grabflure:
    title: "Grabfluren (%ws%)"
    abstract: "Grabfluren je Friedhof, aktueller Stand. Lizenz: CC0-1.0."
    keywords: ["Grabflur", "Friedhof"]
    license: "CC0-1.0"
  grabflure_versionen:
    title: "Grabfluren – Versionen (%ws%)"
    abstract: "Versionshistorie der Grabfluren, bearbeitbar über WFS-T. Lizenz: CC0-1.0."
    keywords: ["Grabflur", "Versionierung"]
    license: "CC0-1.0"
  graeber:
    title: "Gräber (%ws%)"
    abstract: "Gräber je Friedhof, aktueller Stand. Attribute können Angaben zu Verstorbenen enthalten (u. a. Name, Geburts- und Sterbedatum). Lizenz: CC0-1.0."
    keywords: ["Grab", "Friedhof"]
    license: "CC0-1.0"
  graeber_versionen:
    title: "Gräber – Versionen (%ws%)"
    abstract: "Versionshistorie der Gräber, bearbeitbar über WFS-T. Lizenz: CC0-1.0."
    keywords: ["Grab", "Versionierung"]
    license: "CC0-1.0"

raster:                           # in diesem Turn nur parsen und validieren, nicht anwenden
  title: "Friedhofspläne {stadt}"
  abstract: "Georeferenzierte Friedhofspläne (Rasterdaten) für {stadt}. Lizenz: CC0-1.0."
  keywords: ["Friedhofsplan", "Raster", "GeoTIFF"]
```

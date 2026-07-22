# civitas_einrichtung

> Installationsskript für CIVITAS/CORE auf einem dedizierten Proxmox-Knoten.
>
> Installation script for CIVITAS/CORE on a dedicated Proxmox node.

---

## Deutsch

### 1. Zweck

Das Repository `civitas_einrichtung` enthält ein phasenbasiertes, idempotentes
Installationsskript zur automatisierten Einrichtung der CIVITAS/CORE-Plattform
auf einem dedizierten Proxmox-Knoten. Das Skript erstellt eine
Debian-13-Cloud-Image-basierte VM, installiert einen k3s-Single-Node-Cluster,
deployt alle erforderlichen Add-ons und führt abschließend das CIVITAS/CORE-
Deployment (via `cc_cli` in V1 bzw. `helmfile` in V2) sowie eine automatisierte
Verifikation durch.

Es stehen zwei Versionen zur Verfügung:

- **V1** (`install_civitas_core_V1.sh`) – vollständig implementiert,
  produktiv genutzt. Verwendet `cc_cli` für das Plattform-Deployment.
- **V2** (`install_civitas_core_V2.sh`) – helmfile-basierte Neufassung,
  teilweise im Aufbau. Module der V2 enthalten teils TODOs/Stubs.

Die Phasen werden als `-1` bis `3` bezeichnet:

| Phase | Bezeichnung                   | Ort               |
|-------|-------------------------------|-------------------|
| -1    | VM-Provisionierung            | Proxmox-Host      |
| 0     | Preflight-Checks              | Ziel-VM           |
| 1a    | k3s-Installation              | Ziel-VM           |
| 1b    | Add-ons (Helm, cert-manager, nginx-Ingress) | Ziel-VM |
| 2     | CIVITAS/CORE-Plattform        | Ziel-VM           |
| 3     | Verifikation                  | Ziel-VM           |

Läuft das Skript auf dem **Proxmox-Host** (`CIVITAS_CONTEXT=host`, Default),
führt es Phase -1 aus, kopiert sich dann per `scp` in die VM und springt per
`ssh` dorthin, um die Phasen 0–3 innerhalb der VM auszuführen. Wird es
innerhalb der VM gestartet (`CIVITAS_CONTEXT=vm`), überspringt es Phase -1 und
führt nur die Phasen 0–3 aus.

### 2. Zielplattform / Ressourcenbedarf

**Hypervisor:**

- Proxmox VE (getestet auf einem Hetzner-Dedicated-Server)

**VM-Sizing (aus `01_config.sh`):**

| Ressource          | Wert                        | Quelle                     |
|--------------------|-----------------------------|----------------------------|
| vCPU               | `12` (`VM_CORES`)           | `modules_V1/01_config.sh`  |
| RAM                | `40960` MiB = 40 GiB (`VM_RAM_MB`) | `modules_V1/01_config.sh` |
| Disk               | `300` GiB (`VM_DISK_GB`)    | `modules_V1/01_config.sh`  |
| Storage            | `local-zfs-civitas` (ZFS thin-provisioned) | `PROXMOX_STORAGE` |
| Disk-Image         | Debian 13 (Trixie), GenericCloud AMD64 | `CLOUD_IMAGE_URL` |

**Guest-Betriebssystem:** Debian 13 (Trixie), Cloud-Image-basiert.

**Kubernetes-Distribution:** `k3s` (`v1.32.3+k3s1`) als Single-Node-Cluster.
- Traefik ist deaktiviert (`K3S_EXEC_ARGS="--disable traefik"`).
- `local-path-provisioner` bleibt als Default-StorageClass aktiv.
- `servicelb` und `metrics-server` bleiben aktiv (k3s-Standardverhalten).

**Swap muss deaktiviert sein.** Die Preflight-Phase prüft dies und bricht
bei aktivem Swap mit einer Fehlermeldung ab.

### 3. Netzwerk-Abhängigkeiten

Die externe Erreichbarkeit aller CIVITAS/CORE-Endpunkte basiert auf folgendem Aufbau:

1. **WireGuard-Tunnel:** Zwischen der CIVITAS/CORE-VM und einer
   OPNsense-Instanz wird ein WireGuard-Tunnel eingerichtet. Die VM erhält
   eine interne Tunnel-IP (`10.10.10.5/24`), die OPNsense erhält
   `10.10.10.1`. Der Tunnel wird durch das Skript mittels des Templates
   `templates_V1/wg0.conf.tpl` (bzw. `templates_V2/wg0.conf.tpl`) konfiguriert
   und über `wg-quick@wg0` aktiviert. Ohne aktiven Tunnel sind sämtliche
   Dienste von außen nicht erreichbar – auch wenn alle Kubernetes-Komponenten
   fehlerfrei laufen.

2. **HAProxy auf OPNsense:** HAProxy terminiert eingehenden TLS-Traffic auf
   Port 443 und leitet ihn **SNI-basiert per TCP-Passthrough (Layer 4)** an die
   VM weiter (Ziel: `10.10.10.5:443`). Es findet **kein TLS-Eingriff** durch
   HAProxy statt. Das bedeutet:
   - HAProxy entscheidet anhand der Server-Name-Indication (SNI) an welche
     Subdomain (z. B. `idm.<domain>`, `portal.<domain>`) die Verbindung
     weitergeleitet wird.
   - Die TLS-Terminierung erfolgt ausschließlich in der VM durch
     **nginx-Ingress** mit Zertifikaten von **cert-manager** (Staging-Issuer
     oder Let's-Encrypt-Production, gesteuert über `LE_CERT`).

3. **DNS-Einträge:** Für jede Subdomain (`idm.<domain>`, `portal.<domain>`,
   `pgadmin.<domain>`, `geoportal.<domain>`, `superset.<domain>`,
   `monitoring.<domain>`, `api-admin.<domain>`) müssen vorab manuelle
   DNS-Einträge gesetzt werden. Es existiert **kein automatisches
   DNS-Provisioning**. Das Skript gibt in Phase 0 eine Warnung aus, wenn
   `idm.<domain>` oder `portal.<domain>` nicht aufgelöst werden können, bricht
   aber nicht ab.

4. **SOHO-Gateway:** Die VM kommuniziert mit dem Gateway `192.168.aaa.1`
   (`SOHO_GATEWAY`). Die Preflight-Phase prüft die Erreichbarkeit dieses
   Gateways und bricht bei Fehlschlag ab.

Ohne korrekt konfigurierten WireGuard-Tunnel und HAProxy-Weiterleitung bleiben
alle Endpunkte von außen unerreichbar, selbst wenn die Installation in der VM
fehlerfrei abgeschlossen wurde.

### 4. Phasenübersicht (Kurzfassung)

1. **Phase -1 – VM-Provisionierung** (`modules_V1/00_provision_vm.sh`):
   Erstellt die CIVITAS/CORE-VM auf dem Proxmox-Host aus einem
   Debian-13-Cloud-Image: Download (24h-Cache), VM-Anlage (`qm create`),
   Disk-Import, Resize auf 300 GiB, Cloud-Init-Konfiguration (statische IP,
   SSH-Key) und Start mit Warten auf SSH-Erreichbarkeit. Idempotent: Wenn die
   VM mit der konfigurierten `VM_ID` bereits existiert, wird sie übersprungen.

2. **Phase 0 – Preflight-Checks** (`modules_V1/03_preflight.sh`): Prüft
   Betriebssystem (Debian 13), vCPU (min. 4), RAM (min. 16 GiB frei), Disk
   (min. 100 GiB frei), Swap-Status (muss deaktiviert sein), Netzwerk
   (Gateway erreichbar), Zeitzone (Europe/Berlin), inotify-Limits (wird auf
   524288/1024 gesetzt), DNS-Warnung, SMTP-Erreichbarkeit, k3s-Version
   (Idempotenz), PBS-Backup und non-free-APT-Quellen. Fehlende Werkzeuge
   (curl, python3, dig, wg, git u. a.) werden automatisch installiert.

3. **Phase 1a – k3s** (`modules_V1/04_k3s.sh`): Installiert k3s
   (`v1.32.3+k3s1`) per offiziellem Install-Skript, wartet auf die
   k3s-API, kopiert die `kubeconfig`, registriert den Node und wartet auf
   den `Ready`-Status. Idempotent: Überspringt die Installation, wenn k3s
   bereits aktiv ist.

4. **Phase 1b – Add-ons** (`modules_V1/05_addons.sh`): Installiert
   `helm`-CLI (`v3.17.0`), Gateway-API-CRDs (`v1.2.1`), `cert-manager`
   (`v1.16.0`) und den `nginx`-Ingress-Controller (`4.12.0`). Alle
   Komponenten werden als Helm-Charts installiert. Idempotent: Überspringt
   bereits installierte Charts.

5. **Phase 2 – CIVITAS/CORE-Plattform** (`modules_V1/06_civitas.sh`,
   `06a_network_certs.sh`, `06b_idm_provisioning.sh`): Klont das
   CIVITAS/CORE-Deployment-Repository, richtet ein Python-Venv ein,
   installiert `cc_cli`, rendert das Ansible-Inventory aus dem Template
   (`templates_V1/inventory.yml.tpl`), führt `cc_cli validate` und
   `cc_cli exec` aus, konfiguriert WireGuard (`wg0.conf.tpl`), patcht
   Playbook-URLs, kümmert sich um Zertifikate (Staging/Production,
   Backup-Restore) und provisioniert den Keycloak-Admin-User.

6. **Phase 3 – Verifikation** (`modules_V1/07_verify.sh`,
   `07_login_summary.sh`): Führt automatisierte Abnahmeprüfungen durch
   und gibt eine Login-Zusammenfassung mit allen URLs, Accounts und
   Passwortquellen aus.

### 5. Voraussetzungen zum Start

Die Datei `.env.example` im Repository-Stammverzeichnis dient als Vorlage.
Empfohlener Arbeitsablauf:

1. `.env.example` nach `.env.local` kopieren
2. Werte eintragen (Passwörter, Schlüssel, Domain)
3. `.env.local` **nie** committen (in `.gitignore` eingetragen)
4. Skript starten — es erkennt `.env.local` automatisch und überträgt es in die VM

Alternativ können alle Variablen auch direkt als Umgebungsvariablen exportiert werden.

**Pflichtvariablen (Skript bricht ab, wenn nicht gesetzt):**

| Variable               | Beschreibung                                                |
|------------------------|-------------------------------------------------------------|
| `ROOT_PASSWORD`        | Root-Passwort für die VM                                    |
| `DOMAIN_NAME`          | Basis-Domain-Name (z. B. `example.eu`)                     |
| `SMTP_HOST`            | SMTP-Server-Hostname                                        |
| `SMTP_USER`            | SMTP-Benutzer                                               |
| `SMTP_PASS`            | SMTP-Passwort                                               |
| `ADMIN_PASS`           | Plattform-Admin-Passwort (gleichzeitig `master_password`)   |
| `WG_VM_PRIVATE_KEY`    | WireGuard-Private-Key der VM                                |
| `WG_OPN_PUBLIC_KEY`    | WireGuard-Public-Key der OPNsense                           |
| `WG_OPN_ENDPOINT`      | WireGuard-Endpoint (öffentliche IP:Port der OPNsense)       |

**Optionale Variablen (mit Default-Werten und Detail-Erklärung):**

| Variable                 | Default                     | Beschreibung                                                                 |
|--------------------------|-----------------------------|------------------------------------------------------------------------------|
| `CIVITAS_DEBUG`          | nicht gesetzt               | `true` → Ausführliche Debug-Ausgabe während der Installation                |
| `LE_CERT`                | `false`                     | Steuert die Zertifikats-Strategie. Siehe Detail-Erklärung weiter unten.      |
| `NO_NEW_LE_CERT`         | `false`                     | Safety-Schalter: `true` → blockiert **alle** neuen Zertifikatsanforderungen  |
| `CERT_BACKUP_FILE`       | `le-certs-backup.yaml`      | Pfad zum Backup bestehender Let's-Encrypt-Zertifikate (YAML)                |
| `APISIX_DASHBOARD`       | `false`                     | `true` → APISIX-Dashboard nach Installation aktivieren                      |
| `RUN_TESTS`              | `true`                      | `true` → Playwright-E2E-Tests nach der Installation ausführen                |
| `DOMAIN`                 | `udp.<DOMAIN_NAME>`         | Überschreibt die berechnete vollständige Domain inkl. `udp.`-Präfix          |
| `TEST_ID`                | *(kein Default)*            | Identifier für E2E-Tests (z. B. `udp`)                                      |
| `BASE_DOMAIN`            | *(kein Default)*            | Basis-Domain für E2E-Tests (z. B. `example.eu`)                             |
| `RUSTFS_ENDPOINT`        | *(nicht gesetzt)*           | S3-kompatibler Endpoint für RustFS (z. B. `http://192.168.x.x:9000`)        |
| `RUSTFS_ACCESS_KEY`      | *(nicht gesetzt)*           | S3-Access-Key für RustFS                                                    |
| `RUSTFS_SECRET_KEY`      | *(nicht gesetzt)*           | S3-Secret-Key für RustFS                                                    |
| `SMTP_PORT`              | `587`                       | SMTP-Port des ausgehenden Mailservers                                       |
| `ADMIN_EMAIL`            | `admin@<DOMAIN_NAME>`       | E-Mail-Adresse des Plattform-Administrators                                 |
| `WG_PRESHARED_KEY`       | *(leer)*                    | Optionaler Pre-Shared-Key für den WireGuard-Tunnel                          |

**Detail-Erklärung: Zertifikats-Management (`LE_CERT` / `CERT_BACKUP_FILE` / `NO_NEW_LE_CERT`)**

Das Skript verwendet eine Entscheidungsfunktion (`resolve_target_state`), die den
Zielzustand für TLS-Zertifikate anhand folgender Logik ermittelt:

- **`LE_CERT=false`** (Standard): Es werden ausschließlich Let's-Encrypt-Staging-
  Zertifikate verwendet. Es erfolgen keine Production-Anfragen.
- **`CERT_BACKUP_FILE` vorhanden**: Ein bestehendes Backup (z. B. aus einer
  vorherigen Installation mit Production-Zertifikaten) wird wiederhergestellt.
  Dies hat **Vorrang** vor `LE_CERT` — selbst bei `LE_CERT=false` wird ein
  vorhandenes Backup restauriert.
- **`LE_CERT=true` und kein Backup vorhanden**: Es werden neue Let's-Encrypt-
  Production-Zertifikate angefordert.
- **`NO_NEW_LE_CERT=true`**: Safety-Schalter. Selbst wenn alle Bedingungen für
  eine Production-Anfrage erfüllt sind, wird diese blockiert. Nützlich, um
  versehentliche Raten-Limits bei Let's-Encrypt zu vermeiden.

**Hinweise zum Arbeitsablauf:**

- `.env.example` dient ausschließlich als Vorlage — **nie direkt ausführen**.
- Die Datei `.env.local` wird automatisch vom Skript erkannt und per `scp` in
  die VM übertragen (bei Ausführung vom Proxmox-Host).
- Werte mit `****` in `.env.example` sind Platzhalter und müssen ersetzt werden.

**Weitere Voraussetzungen:**

- Der Proxmox-Host muss das Kommando `qm` (Proxmox VE) sowie `curl` und `ssh`
  bereitstellen.
- Ein SSH-Public-Key muss unter `${HOME}/.ssh/authorized_keys` existieren
  (für den Zugriff auf die VM).
- Der Proxmox-Storage `local-zfs-civitas` muss existieren.
- Ein Proxmox Backup Server (PBS) mit dem Storage `backup-p2d2-kinglui` ist
  empfohlen (wird in Phase 0 geprüft).

### 6. Bekannte Einschränkungen / Entwicklungsstatus

- **Single-Node-Cluster:** Das Setup läuft auf einem einzelnen k3s-Node. Es
  gibt keine Hochverfügbarkeit (HA). Das Skript ist für Entwicklungs- und
  Evaluationszwecke konzipiert, nicht für einen Vollproduktivbetrieb.
- **V1 ist stabil, V2 im Aufbau:** V1 (`install_civitas_core_V1.sh`) ist
  vollständig implementiert und wird produktiv genutzt. V2
  (`install_civitas_core_V2.sh`) ist in der Entwicklung und enthält in
  mehreren Modulen noch TODOs und auskommentierte Implementierungsschritte.
- **Kein automatisches DNS-Provisioning:** DNS-Einträge für die Subdomains
  müssen manuell gesetzt werden. Ohne korrekte DNS-Auflösung ist die
  Plattform nicht erreichbar.
- **Abhängigkeit von OPNsense/HAProxy:** Ohne eine korrekt konfigurierte
  OPNsense-Instanz mit HAProxy und WireGuard-Tunnel sind alle Endpunkte von
  außen nicht erreichbar (siehe Abschnitt 3).
- **Zertifikats-Management:** Standardmäßig werden nur
  Let's-Encrypt-Staging-Zertifikate ausgestellt. Für Production-Zertifikate
  muss `LE_CERT=true` gesetzt werden. Ein Safety-Schalter
  (`NO_NEW_LE_CERT`) kann neue Zertifikatsanforderungen blockieren.
- **E2E-Tests:** Playwright-basierte E2E-Tests sind in Vorbereitung
  (steuerbar über `RUN_TESTS`), aber noch nicht vollständig integriert
  (bekannter offener Punkt: `BASE_DOMAIN`-Fehler in der tests-`.env`-
  Generierung).

### 7. Lizenz / Ansprechpartner

- **Lizenz:** Derzeit nicht spezifiziert. Bei Fragen zur Nutzung wenden Sie
  sich bitte an den Projektverantwortlichen.
- **Ansprechpartner:** Peter König (Projektverantwortlicher) –
  Kontaktaufnahme über das CIVITAS/CORE-Projektteam.
- **Repository:** Dieses Repository ist Teil des CIVITAS/CORE-Ökosystems und
  wird im Rahmen des p2d2-Projekts (Public-Public Data-DNA) entwickelt.
  Siehe auch: <https://www.data-dna.eu>

---

## English

### 1. Purpose

The `civitas_einrichtung` repository provides a phase-based, idempotent
installation script for automated provisioning of the CIVITAS/CORE platform on
a dedicated Proxmox node. The script creates a Debian 13 Cloud-Image-based VM,
installs a k3s single-node cluster, deploys all required add-ons, and runs the
CIVITAS/CORE deployment (via `cc_cli` in V1 or `helmfile` in V2) followed by
automated verification.

Two versions are available:

- **V1** (`install_civitas_core_V1.sh`) – fully implemented, used in
  production. Uses `cc_cli` for the platform deployment.
- **V2** (`install_civitas_core_V2.sh`) – helmfile-based redesign, partially
  under construction. V2 modules contain TODOs and stubs in several places.

The phases are numbered `-1` through `3`:

| Phase | Name                          | Location           |
|-------|-------------------------------|--------------------|
| -1    | VM provisioning               | Proxmox host       |
| 0     | Preflight checks              | Target VM          |
| 1a    | k3s installation              | Target VM          |
| 1b    | Add-ons (Helm, cert-manager, nginx-Ingress) | Target VM |
| 2     | CIVITAS/CORE platform         | Target VM          |
| 3     | Verification                  | Target VM          |

When run on the **Proxmox host** (`CIVITAS_CONTEXT=host`, default), the script
executes phase -1, copies itself via `scp` to the VM, and SSH-hops into the VM
to run phases 0–3 inside it. When run **inside the VM** (`CIVITAS_CONTEXT=vm`),
it skips phase -1 and executes phases 0–3 only.

### 2. Target Platform / Resource Requirements

**Hypervisor:**

- Proxmox VE (tested on a Hetzner dedicated server)

**VM sizing (from `01_config.sh`):**

| Resource          | Value                        | Source                     |
|-------------------|------------------------------|----------------------------|
| vCPU              | `12` (`VM_CORES`)            | `modules_V1/01_config.sh`  |
| RAM               | `40960` MiB = 40 GiB (`VM_RAM_MB`) | `modules_V1/01_config.sh` |
| Disk              | `300` GiB (`VM_DISK_GB`)     | `modules_V1/01_config.sh`  |
| Storage           | `local-zfs-civitas` (ZFS thin-provisioned) | `PROXMOX_STORAGE` |
| Disk image        | Debian 13 (Trixie), GenericCloud AMD64 | `CLOUD_IMAGE_URL` |

**Guest OS:** Debian 13 (Trixie), Cloud-Image-based.

**Kubernetes distribution:** `k3s` (`v1.32.3+k3s1`) as a single-node cluster.
- Traefik is disabled (`K3S_EXEC_ARGS="--disable traefik"`).
- `local-path-provisioner` remains active as the default StorageClass.
- `servicelb` and `metrics-server` remain active (k3s default behavior).

**Swap must be disabled.** The preflight phase checks this and aborts with an
error if swap is active.

### 3. Network Dependencies

**This section is particularly important because the network architecture is
often overlooked.**

The VM is **not directly reachable from the public internet.** External
access to all CIVITAS/CORE endpoints is based on the following setup:

1. **WireGuard tunnel:** A WireGuard tunnel is established between the
   CIVITAS/CORE VM and an OPNsense instance. The VM receives an internal
   tunnel IP (`10.10.10.5/24`), OPNsense receives `10.10.10.1`. The tunnel is
   configured by the script using the template
   `templates_V1/wg0.conf.tpl` (or `templates_V2/wg0.conf.tpl`) and activated
   via `wg-quick@wg0`. Without an active tunnel, all services are unreachable
   from the outside – even if all Kubernetes components are running correctly.

2. **HAProxy on OPNsense:** HAProxy terminates incoming TLS traffic on port
   443 and forwards it **SNI-based via TCP passthrough (Layer 4)** to the VM
   (target: `10.10.10.5:443`). **No TLS interception** occurs at HAProxy.
   This means:
   - HAProxy decides based on the Server-Name-Indication (SNI) which subdomain
     (e.g., `idm.<domain>`, `portal.<domain>`) the connection should be
     forwarded to.
   - TLS termination happens exclusively inside the VM by
     **nginx-Ingress** using certificates from **cert-manager** (staging issuer
     or Let's-Encrypt production, controlled via `LE_CERT`).

3. **DNS records:** For each subdomain (`idm.<domain>`, `portal.<domain>`,
   `pgadmin.<domain>`, `geoportal.<domain>`, `superset.<domain>`,
   `monitoring.<domain>`, `api-admin.<domain>`), DNS records must be created
   manually beforehand. **No automatic DNS provisioning** exists. The script
   issues a warning during phase 0 if `idm.<domain>` or `portal.<domain>`
   cannot be resolved, but does not abort.

4. **SOHO gateway:** The VM communicates via gateway `192.168.12.1`
   (`SOHO_GATEWAY`). The preflight phase checks the reachability of this
   gateway and aborts on failure.

**Consequence:** Without a correctly configured WireGuard tunnel and HAProxy
forwarding, all endpoints remain unreachable from the outside, even if the
installation inside the VM completed successfully.

### 4. Phase Overview (Short Form)

1. **Phase -1 – VM provisioning** (`modules_V1/00_provision_vm.sh`): Creates
   the CIVITAS/CORE VM on the Proxmox host from a Debian 13 Cloud-Image:
   download (24h cache), VM creation (`qm create`), disk import, resize to
   300 GiB, Cloud-Init configuration (static IP, SSH key), and startup with
   SSH wait. Idempotent: Skips if a VM with the configured `VM_ID` already
   exists.

2. **Phase 0 – Preflight checks** (`modules_V1/03_preflight.sh`): Checks
   operating system (Debian 13), vCPU (min. 4), RAM (min. 16 GiB free), disk
   (min. 100 GiB free), swap status (must be disabled), network (gateway
   reachable), timezone (Europe/Berlin), inotify limits (set to 524288/1024),
   DNS warning, SMTP reachability, k3s version (idempotency), PBS backup, and
   non-free APT sources. Missing tools (curl, python3, dig, wg, git, etc.)
   are installed automatically.

3. **Phase 1a – k3s** (`modules_V1/04_k3s.sh`): Installs k3s
   (`v1.32.3+k3s1`) via the official install script, waits for the k3s API,
   copies the `kubeconfig`, registers the node, and waits for `Ready` status.
   Idempotent: Skips installation if k3s is already active.

4. **Phase 1b – Add-ons** (`modules_V1/05_addons.sh`): Installs `helm` CLI
   (`v3.17.0`), Gateway API CRDs (`v1.2.1`), `cert-manager` (`v1.16.0`), and
   the `nginx` Ingress Controller (`4.12.0`). All components are installed as
   Helm charts. Idempotent: Skips already installed charts.

5. **Phase 2 – CIVITAS/CORE platform** (`modules_V1/06_civitas.sh`,
   `06a_network_certs.sh`, `06b_idm_provisioning.sh`): Clones the
   CIVITAS/CORE deployment repository, sets up a Python virtual environment,
   installs `cc_cli`, renders the Ansible inventory from the template
   (`templates_V1/inventory.yml.tpl`), runs `cc_cli validate` and
   `cc_cli exec`, configures WireGuard (`wg0.conf.tpl`), patches playbook
   URLs, handles certificates (staging/production, backup restore), and
   provisions the Keycloak admin user.

6. **Phase 3 – Verification** (`modules_V1/07_verify.sh`,
   `07_login_summary.sh`): Runs automated acceptance tests and outputs a
   login summary with all URLs, accounts, and password sources.

### 5. Prerequisites for Starting

The `.env.example` file in the repository root serves as a template.
Recommended workflow:

1. Copy `.env.example` to `.env.local`
2. Fill in the values (passwords, keys, domain)
3. **Never commit** `.env.local` (it is listed in `.gitignore`)
4. Start the script — it automatically detects `.env.local` and transfers it to the VM

Alternatively, all variables can be exported directly as environment variables.

**Required variables (script aborts if not set):**

| Variable               | Description                                             |
|------------------------|---------------------------------------------------------|
| `ROOT_PASSWORD`        | Root password for the VM                                |
| `DOMAIN_NAME`          | Base domain name (e.g., `example.eu`)                   |
| `SMTP_HOST`            | SMTP server hostname                                    |
| `SMTP_USER`            | SMTP user                                               |
| `SMTP_PASS`            | SMTP password                                           |
| `ADMIN_PASS`           | Platform admin password (also used as `master_password`)|
| `WG_VM_PRIVATE_KEY`    | WireGuard private key of the VM                         |
| `WG_OPN_PUBLIC_KEY`    | WireGuard public key of the OPNsense                    |
| `WG_OPN_ENDPOINT`      | WireGuard endpoint (public IP:port of the OPNsense)     |

**Optional variables (with defaults and detailed explanation):**

| Variable                 | Default                     | Description                                                                |
|--------------------------|-----------------------------|----------------------------------------------------------------------------|
| `CIVITAS_DEBUG`          | not set                     | `true` → verbose debug output during installation                          |
| `LE_CERT`                | `false`                     | Controls the certificate strategy. See detailed explanation below.         |
| `NO_NEW_LE_CERT`         | `false`                     | Safety switch: `true` → blocks **all** new certificate requests           |
| `CERT_BACKUP_FILE`       | `le-certs-backup.yaml`      | Path to a backup of existing Let's-Encrypt certificates (YAML)            |
| `APISIX_DASHBOARD`       | `false`                     | `true` → enable APISIX dashboard after installation                        |
| `RUN_TESTS`              | `true`                      | `true` → run Playwright E2E tests after installation                       |
| `DOMAIN`                 | `udp.<DOMAIN_NAME>`         | Overrides the computed full domain including the `udp.` prefix             |
| `TEST_ID`                | *(no default)*              | Identifier for E2E tests (e.g., `udp`)                                     |
| `BASE_DOMAIN`            | *(no default)*              | Base domain for E2E tests (e.g., `example.eu`)                             |
| `RUSTFS_ENDPOINT`        | *(not set)*                 | S3-compatible endpoint for RustFS (e.g., `http://192.168.x.x:9000`)       |
| `RUSTFS_ACCESS_KEY`      | *(not set)*                 | S3 access key for RustFS                                                   |
| `RUSTFS_SECRET_KEY`      | *(not set)*                 | S3 secret key for RustFS                                                   |
| `SMTP_PORT`              | `587`                       | SMTP port of the outgoing mail server                                      |
| `ADMIN_EMAIL`            | `admin@<DOMAIN_NAME>`       | Email address of the platform administrator                                |
| `WG_PRESHARED_KEY`       | *(empty)*                   | Optional pre-shared key for the WireGuard tunnel                           |

**Detailed explanation: Certificate management (`LE_CERT` / `CERT_BACKUP_FILE` / `NO_NEW_LE_CERT`)**

The script uses a decision function (`resolve_target_state`) that determines the
target state for TLS certificates based on the following logic:

- **`LE_CERT=false`** (default): Only Let's-Encrypt staging certificates are
  used. No production requests are made.
- **`CERT_BACKUP_FILE` exists**: An existing backup (e.g., from a previous
  installation with production certificates) is restored. This takes **precedence**
  over `LE_CERT` — even with `LE_CERT=false`, an existing backup is restored.
- **`LE_CERT=true` and no backup exists**: New Let's-Encrypt production
  certificates are requested.
- **`NO_NEW_LE_CERT=true`**: Safety switch. Even if all conditions for a
  production request are met, it is blocked. Useful for preventing accidental
  rate-limit hits at Let's-Encrypt.

**Workflow notes:**

- `.env.example` is a template only — **never run it directly**.
- The `.env.local` file is automatically detected by the script and transferred
  via `scp` to the VM (when running from the Proxmox host).
- Values marked with `****` in `.env.example` are placeholders and must be replaced.

**Further requirements:**

- The Proxmox host must provide the `qm` command (Proxmox VE), `curl`, and
  `ssh`.
- An SSH public key must exist at `${HOME}/.ssh/authorized_keys` (for VM
  access).
- The Proxmox storage `local-zfs-civitas` must exist.
- A Proxmox Backup Server (PBS) with storage `backup-p2d2-kinglui` is
  recommended (checked in phase 0).


### 6. Known Limitations / Development Status

- **Single-node cluster:** The setup runs on a single k3s node. There is no
  high availability (HA). The script is designed for development and
  evaluation purposes, not for full production operation.
- **V1 is stable, V2 under construction:** V1 (`install_civitas_core_V1.sh`)
  is fully implemented and used in production. V2
  (`install_civitas_core_V2.sh`) is under development and still contains
  TODOs and commented-out implementation steps in several modules.
- **No automatic DNS provisioning:** DNS records for subdomains must be set
  manually. Without correct DNS resolution, the platform is unreachable.
- **Dependency on OPNsense/HAProxy:** Without a correctly configured OPNsense
  instance with HAProxy and a WireGuard tunnel, all endpoints are unreachable
  from the outside (see section 3).
- **Certificate management:** By default, only Let's-Encrypt staging
  certificates are issued. For production certificates, set `LE_CERT=true`. A
  safety switch (`NO_NEW_LE_CERT`) can block new certificate requests.
- **E2E tests:** Playwright-based E2E tests are in preparation (controllable
  via `RUN_TESTS`) but not yet fully integrated (known open issue:
  `BASE_DOMAIN` error in the test `.env` generation).

### 7. License / Contact

- **License:** Not specified at this time. For licensing inquiries, please
  contact the project lead.
- **Contact:** Peter König (project lead) – reachable via the CIVITAS/CORE
  project team.
- **Repository:** This repository is part of the CIVITAS/CORE ecosystem and
  is developed within the p2d2 project (Public-Public Data-DNA).
  See also: <https://www.data-dna.eu>

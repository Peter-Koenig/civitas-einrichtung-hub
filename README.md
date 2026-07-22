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

**Dieser Abschnitt ist besonders wichtig, da die Netzwerk-Architektur oft
übersehen wird.**

Die VM ist **nicht direkt öffentlich erreichbar**. Die externe Erreichbarkeit
aller CIVITAS/CORE-Endpunkte basiert auf folgendem Aufbau:

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

4. **SOHO-Gateway:** Die VM kommuniziert mit dem Gateway `192.168.12.1`
   (`SOHO_GATEWAY`). Die Preflight-Phase prüft die Erreichbarkeit dieses
   Gateways und bricht bei Fehlschlag ab.

**Konsequenz:** Ohne korrekt konfigurierten WireGuard-Tunnel und
HAProxy-Weiterleitung bleiben alle Endpunkte von außen unerreichbar, selbst
wenn die Installation in der VM fehlerfrei abgeschlossen wurde.

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

**Benötigte Umgebungsvariablen (vor Skript-Start exportieren oder in
`.env.local` setzen):**

| Variable               | Beschreibung                                      |
|------------------------|---------------------------------------------------|
| `ROOT_PASSWORD`        | Root-Passwort für die VM                          |
| `SMTP_HOST`            | SMTP-Server-Hostname                              |
| `SMTP_USER`            | SMTP-Benutzer                                     |
| `SMTP_PASS`            | SMTP-Passwort                                     |
| `ADMIN_PASS`           | Plattform-Admin-Passwort (master_password)        |
| `WG_VM_PRIVATE_KEY`    | WireGuard-Private-Key der VM                      |
| `WG_OPN_PUBLIC_KEY`    | WireGuard-Public-Key der OPNsense                 |
| `WG_OPN_ENDPOINT`      | WireGuard-Endpoint (öffentliche IP:Port der OPNsense) |
| `DOMAIN_NAME`          | Domain-Name (z. B. `example.org`)                 |

**Optionale Umgebungsvariablen:**

| Variable                 | Default            | Beschreibung                                      |
|--------------------------|--------------------|---------------------------------------------------|
| `LE_CERT`                | `false`            | `true` → Let's-Encrypt-Production-Zertifikate anfordern |
| `LE_REQUESTS_BLOCKED`    | `false`            | `true` → Safety-Schalter: keine neuen Zertifikatsanforderungen |
| `APISIX_DASHBOARD`       | `false`            | `true` → APISIX-Dashboard aktivieren              |
| `RUN_TESTS`              | `false`            | `true` → E2E-Tests nach Installation ausführen    |
| `WG_PRESHARED_KEY`       | *(leer)*           | Optionaler Pre-Shared-Key für WireGuard           |
| `LOG_FILE`               | *(leer)*           | Pfad zu einer Logdatei (z. B. `/var/log/civitas_install_v1.log`) |
| `CIVITAS_CONTEXT`        | `host`             | `host` (von Proxmox) oder `vm` (innerhalb der VM) |
| `CREDENTIALS_OUTPUT_PATH`| `/root/civitas-install/credentials.env` | Zielpfad für generierte Dienst-Passwörter |

**Optionale `.env.local`-Datei:**

Alle oben genannten Variablen können auch in einer Datei `.env.local` im
Repository-Stammverzeichnis abgelegt werden. Diese wird beim Start des Skripts
automatisch erkannt und in die VM übertragen. Beispiel:

```
ROOT_PASSWORD="mein-sicheres-passwort"
SMTP_HOST="mail.example.org"
SMTP_USER="no-reply@example.org"
SMTP_PASS="smtp-passwort"
ADMIN_PASS="admin-passwort"
WG_VM_PRIVATE_KEY="..."
WG_OPN_PUBLIC_KEY="..."
WG_OPN_ENDPOINT="opnsense.example.org:51820"
DOMAIN_NAME="example.org"
```

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
  (`LE_REQUESTS_BLOCKED`) kann neue Zertifikatsanforderungen blockieren.
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

**Required environment variables (export before script start or set in
`.env.local`):**

| Variable               | Description                                      |
|------------------------|---------------------------------------------------|
| `ROOT_PASSWORD`        | Root password for the VM                          |
| `SMTP_HOST`            | SMTP server hostname                              |
| `SMTP_USER`            | SMTP user                                         |
| `SMTP_PASS`            | SMTP password                                     |
| `ADMIN_PASS`           | Platform admin password (master_password)         |
| `WG_VM_PRIVATE_KEY`    | WireGuard private key of the VM                   |
| `WG_OPN_PUBLIC_KEY`    | WireGuard public key of the OPNsense              |
| `WG_OPN_ENDPOINT`      | WireGuard endpoint (public IP:port of OPNsense)   |
| `DOMAIN_NAME`          | Domain name (e.g., `example.org`)                 |

**Optional environment variables:**

| Variable                 | Default                     | Description                                   |
|--------------------------|-----------------------------|-----------------------------------------------|
| `LE_CERT`                | `false`                     | `true` → request Let's-Encrypt production certificates |
| `LE_REQUESTS_BLOCKED`    | `false`                     | `true` → safety switch: block all new certificate requests |
| `APISIX_DASHBOARD`       | `false`                     | `true` → enable APISIX dashboard              |
| `RUN_TESTS`              | `false`                     | `true` → run E2E tests after installation     |
| `WG_PRESHARED_KEY`       | *(empty)*                   | Optional pre-shared key for WireGuard         |
| `LOG_FILE`               | *(empty)*                   | Path to a log file (e.g., `/var/log/civitas_install_v1.log`) |
| `CIVITAS_CONTEXT`        | `host`                      | `host` (from Proxmox) or `vm` (inside the VM) |
| `CREDENTIALS_OUTPUT_PATH`| `/root/civitas-install/credentials.env` | Target path for generated service passwords |

**Optional `.env.local` file:**

All variables above can also be placed in a `.env.local` file in the
repository root directory. It is automatically detected and transferred to the
VM when the script starts. Example:

```
ROOT_PASSWORD="my-secure-password"
SMTP_HOST="mail.example.org"
SMTP_USER="no-reply@example.org"
SMTP_PASS="smtp-password"
ADMIN_PASS="admin-password"
WG_VM_PRIVATE_KEY="..."
WG_OPN_PUBLIC_KEY="..."
WG_OPN_ENDPOINT="opnsense.example.org:51820"
DOMAIN_NAME="example.org"
```

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
  safety switch (`LE_REQUESTS_BLOCKED`) can block new certificate requests.
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
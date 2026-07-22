# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2025 CIVITAS/CORE Contributors
#
# Licensed under the EUPL, Version 1.2 only (the "Licence");
# You may not use this work except in compliance with the Licence.
# You may obtain a copy of the Licence at:
#   https://joinup.ec.europa.eu/software/page/eupl
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the Licence is distributed on an "AS IS" basis,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the Licence for the specific language governing permissions and
# limitations under the Licence.
# yaml-language-server: $schema=https://gitlab.com/civitas-connect/civitas-core/civitas-core/-/raw/main/core_platform/inventory_schema.json
# Inventory for the Open City Platform
# Erzeugt durch install_civitas_core.sh → render_inventory
# Alle PLACEHOLDER_*-Tokens werden durch sed in modules/06_civitas.sh ersetzt.
#
# TLS-Terminierung durch Caddy auf OPNsense (Variante A):
#   http: false → nginx-Ingress erwartet keinen direkten HTTPS-Eingang
#   capath: ""  → keine interne CA nötig
#   ssl-redirect wird per kubectl annotate nachträglich deaktiviert
#
# Dateiname muss cc_cli_inventory.yml heißen wenn cc_cli validate/exec aufgerufen wird.
---
all:
  vars:
    DOMAIN: "PLACEHOLDER_DOMAIN"
    ENVIRONMENT: "PLACEHOLDER_ENVIRONMENT"
    kubeconfig_file: PLACEHOLDER_KUBECONFIG

  children:
    controller:
      hosts:
        localhost:
          ansible_host: 127.0.0.1
          ansible_connection: local
          ansible_python_interpreter: "{{ ansible_playbook_python }}"
      vars:

        inv_k8s:
          config:
            context: "PLACEHOLDER_K8S_CONTEXT"
          storage_class:
            rwo: "PLACEHOLDER_STORAGECLASS_RWO"
            rwx: "PLACEHOLDER_STORAGECLASS_RWX"
            loc: "PLACEHOLDER_STORAGECLASS_LOC"
          ingress:
            ca_path: "/usr/local/share/ca-certificates/civitas-core-ca.crt"
            http: true
          cert_manager:
            le_email: ""
            issuer_name: "PLACEHOLDER_CERTMANAGER_ISSUER"
            create_letsencrypt_issuer: false
          ingress_class: "PLACEHOLDER_INGRESSCLASS"
          gitlab_access:
            user_email: ""
            user: ""
            token: ""

        inv_op_stack:
          keel_operator:
            enable: false
            admin: "PLACEHOLDER_ADMINEMAIL"
            password: "PLACEHOLDER_PGADMIN_PASSWORD"
          pgadmin:
            enable: true
            default_email: "PLACEHOLDER_ADMINEMAIL"
            default_password: "PLACEHOLDER_PGADMIN_PASSWORD"
          kyverno_operator:
            enable: false
          monitoring:
            enable: true
            prometheus:
              enable: true
            grafana:
              enable: true
            alertmanager:
              enable: true
            loki:
              enable: true
            alloy:
              enable: true

          velero:
            enable: false
            backup:
              location_name: "CHANGE_ME"
              access_key: ""
              bucket: ""
              region: ""
              endpoint: ""
              secret: ""

        inv_central_db:
          enable: true
          ns_create: true
          ns_name: PLACEHOLDER_ENVIRONMENT-database-stack
          port: "5432"
          pg_version: "16"
          replicas: 1
          storage_size: 20Gi
          enable_logical_backup: false
          spilo_postgres_image:
            image_registry: ghcr.io
            image_repository: zalando/spilo-16
            image_tag: "3.3-p1"

        inv_access:
          enable: true
          platform:
            admin_first_name: Admin
            admin_surname: Admin
            admin_email: "PLACEHOLDER_ADMINEMAIL"
            master_username: "PLACEHOLDER_ADMINEMAIL"
            master_password: "PLACEHOLDER_KEYCLOAK_ADMIN_PASSWORD"
            k8s_secret_name: PLACEHOLDER_ENVIRONMENT-keycloak-admin
            hostname: "https://idm.PLACEHOLDER_DOMAIN"
          keycloak:
            enable: true
            log_level: INFO
            replicas: 1
            enable_logical_backup: false
            theme: keycloak
            password_policy:
              length: 12
              digits: 1
              lowerCase: 1
              upperCase: 1
              specialChars: 1
              notUsername: true
              forceExpiredPasswordChange: false
              passwordHistory: 5
          apisix:
            enable: true
            dashboard:
              enable: PLACEHOLDER_APISIX_DASHBOARD
            api_credentials:
              admin_role: "PLACEHOLDER_APISIX_ADMIN_ROLE_KEY"
              viewer_role: "PLACEHOLDER_APISIX_VIEWER_ROLE_KEY"
          service_portal:
            enable: true
            certs:
              enable: false
            oidc:
              enable: false

        inv_cm:
          frost:
            enable: false
            mqtt:
              enable: false
              session_affinity: None
          quantumleap:
            enable: false
          stellio:
            enable: false
            helm_credentials:
              username: ""
              password: ""

        inv_da:
          superset:
            enable: true
            mapbox_api_token: "TODO_PLEASE_SET_A_VALUE"
            db_secret: "PLACEHOLDER_SUPERSET_DB_SECRET"
            admin_user_name: admin
            admin_user_password: "PLACEHOLDER_SUPERSET_ADMIN_PASSWORD"
            redis_auth_password: "PLACEHOLDER_SUPERSET_REDIS_PASSWORD"
          grafana:
            enable: false
            admin: admin
            password: "PLACEHOLDER_GRAFANA_PASSWORD"

        inv_gd:
          enable: true
          gd_components:
            - enable: true
              path: "masterportal"
              instance_name: "Standard"
              masterportal:
                image_registry: "registry.gitlab.com"
                image_repository: "civitas-connect/civitas-core/civitas-core-v1/geoportal-components/geoportal"
                image_tag: "v1.7.0"
          mapfish:
            enable: false
            image_registry: "registry.gitlab.com"
            image_repository: "civitas-connect/civitas-core/civitas-core-v1/geoportal-components/mapfish_print"
            image_tag: "v1.7.0"
          geoserver:
            enable: true
            prefix: ""
            geoserverPassword: "PLACEHOLDER_GEOSERVER_PASSWORD"
          portal_backend:
            enable: true
            image_registry: "registry.gitlab.com"
            image_repository: "civitas-connect/civitas-core/civitas-core-v1/geoportal-components/geoportal_backend"
            image_tag: "v1.7.0"
            s3_backend:
              enable: PLACEHOLDER_S3_ENABLE
              endpoint: "PLACEHOLDER_S3_ENDPOINT"
              access_key_id: "PLACEHOLDER_S3_ACCESS_KEY"
              secret_access_key: "PLACEHOLDER_S3_SECRET_KEY"
              bucket_name: "PLACEHOLDER_S3_BUCKET_NAME"
              region: "PLACEHOLDER_S3_REGION"
              force_path_style: PLACEHOLDER_S3_FORCE_PATH_STYLE

        inv_addons:
          import: false
          addons: []

        inv_checks:
          enable: true
          api:
            default_max_retries: 20
          deployment:
            default_max_retries: 30

        inv_email:
          server: "PLACEHOLDER_SMTP_HOST"
          user: "PLACEHOLDER_SMTP_USER"
          password: "PLACEHOLDER_SMTP_PASS"
          email_from: "PLACEHOLDER_SMTP_FROM"

        inv_datacatalog:
          piveau:
            enable: false
            hub_repo:
              api_keys: []
              virtuoso:
                password: "PLACEHOLDER_PIVAU_PASSWORD"
            hub_search:
              api_key: "CHANGE_ME"

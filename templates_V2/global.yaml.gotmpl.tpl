# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2025 p2d2 Contributors
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
global:
  domain: __DOMAIN__
  instanceSlug: __INSTANCE_SLUG__
  profile: development
  createNamespaces: true
  singleNamespace: true
  serviceMesh:
    enable: false
    type: linkerd
    patchNamespaces: false
  ingress:
    enabled: true
    clusterIssuer: 'selfsigned-ca'
    ingressClass: 'nginx'
  storage:
    storageClass:
      rwo: 'local-path'
      rwx: 'local-path'
      loc: 'local-path'
  metrics:
    enabled: false
  initialUserEmail: __ADMIN_EMAIL__

components:
  - prepare
  - secrets
  - postgres
  - etcd
  - kafka
  - keycloak
  - apisix
  - apicurio
  - model-atlas
  - redpanda-connect
  - portal
  - config-adapters
  - opa
  - authz-repo

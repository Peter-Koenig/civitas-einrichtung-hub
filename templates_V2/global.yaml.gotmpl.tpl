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

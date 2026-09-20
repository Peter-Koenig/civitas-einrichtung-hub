# Multi-Stage-Build für das p2d2-Frontend (Astro SSR, standalone).
#
# Stufe 1 (build):    node:20      — npm ci + npm run build:de1 IM Container.
# Stufe 2 (runtime):  node:20-slim — übernimmt dist/ + node_modules.
#
# Der Build läuft damit IM Container (nicht auf dem k3s-Node): der Host braucht nur
# git (Clone) + docker + k3s ctr — kein Node.js/npm.
#
# Git-Token-Hygiene: Der Clone passiert auf dem Host; .git/ wird per .dockerignore
# aus dem Build-Kontext ausgeschlossen, damit das Token nicht ins Image gelangt.
#
# Server-seitige Secrets (DB_*, WFST_*, SMTP_*, OIDC_*/ZITADEL_*, SESSION_SECRET)
# werden NICHT ins Image gebacken — sie kommen weiterhin per envFrom aus den
# ConfigMaps/Secrets (siehe k8s/VARIABLES.md).

# ── Build-Stage ──────────────────────────────────────────────────────────────
FROM node:20 AS build

ARG PUBLIC_SITE_URL
ARG PUBLIC_WFST_ENDPOINT
ARG PUBLIC_WFST_WORKSPACE
ARG PUBLIC_MAPSERVER_URL
ENV PUBLIC_SITE_URL=${PUBLIC_SITE_URL} \
    PUBLIC_WFST_ENDPOINT=${PUBLIC_WFST_ENDPOINT} \
    PUBLIC_WFST_WORKSPACE=${PUBLIC_WFST_WORKSPACE} \
    PUBLIC_MAPSERVER_URL=${PUBLIC_MAPSERVER_URL}

WORKDIR /app

# Abhängigkeiten zuerst (Layer-Cache für npm ci).
# p2d2 ist ein npm-Workspaces-Monorepo: vor `npm ci` auch die package.json des
# Workspace-Pakets bereitstellen, sonst scheitert die `workspace:*`-Auflösung
# (EUNSUPPORTEDPROTOCOL). Das Root-package.json deklariert genau ein Workspace:
# `workspaces: ["packages/core"]`.
COPY package*.json ./
COPY packages/core/package.json ./packages/core/
RUN npm ci

# Quellen kopieren und die Stage bauen.
COPY . .
RUN npm run build:de1

# ── Runtime-Stage ────────────────────────────────────────────────────────────
FROM node:20-slim

ENV NODE_ENV=production
WORKDIR /app

# Der Astro-Standalone-Adapter externalisiert Laufzeit-Dependencies (z. B. `vue`),
# daher muss node_modules im Image vorhanden sein.
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist

EXPOSE 4321
CMD ["node", "dist/server/entry.mjs"]

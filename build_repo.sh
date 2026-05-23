#!/usr/bin/env bash
set -euo pipefail
# build_repo.sh
# Створює повну структуру репозиторію G.E.N.A. 4.0
# НЕ включає основний інсталер k3s-install.sh або signal_main.py — додайте їх вручну.

OUTDIR="gena-4.0-site"
echo "Створюю структуру в: $OUTDIR"

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"/{docs,docs/mermaid,manifests,ci,site/assets/images}

# --- Основні файли ---
cat > "$OUTDIR/README.md" <<'EOF'
# G.E.N.A. 4.0 — GitOps & Engineering Network Assistant

**Коротко**  
Enterprise hardened single‑node K3s platform (Debian 12 / Ubuntu 22.04+). Моніторинг, логування, алерти через Signal, ArgoCD GitOps, Cert‑Manager + Cloudflare DNS, Portainer.

**Швидкий старт**
1. Клонувати репозиторій.
2. Налаштувати GitHub Secrets: CF_API_TOKEN, WEBHOOK_TOKEN, GRAFANA_ADMIN_PASSWORD, USER_EMAIL, SIGNAL_NUMBER, SIGNAL_RECIPIENTS, ARGOCD_HOST, GRAFANA_HOST.
3. Додати ваш основний інсталер `k3s-install.sh` у корінь.
4. Запустити `sudo ./k3s-install.sh` або слідувати `docs/deployment.md`.
EOF

cat > "$OUTDIR/LICENSE" <<'EOF'
MIT License
EOF

cat > "$OUTDIR/CONTRIBUTING.md" <<'EOF'
# Contributing
- Open issues for bugs or feature requests.
- Fork the repo and submit PRs against main.
- Do not commit secrets or credentials.
EOF

cat > "$OUTDIR/CODE_OF_CONDUCT.md" <<'EOF'
# Code of Conduct
Be respectful. Follow community guidelines. Report violations to maintainers.
EOF

cat > "$OUTDIR/CHECKLIST.md" <<'EOF'
# Pre-deploy Checklist
- DNS: A/CAA records for GRAFANA_HOST, ARGOCD_HOST, PORTAINER_HOST.
- Ports: 22, 80, 443, 6443, 9090 reachable.
- Secrets: CF_API_TOKEN, WEBHOOK_TOKEN, GRAFANA_ADMIN_PASSWORD, USER_EMAIL, SIGNAL_NUMBER, SIGNAL_RECIPIENTS set in GitHub Secrets or Vault.
- Backups: PVC backups for Prometheus, Loki, GitLab, MS SQL.
EOF

cat > "$OUTDIR/Makefile" <<'EOF'
.PHONY: install deploy clean
install:
    @echo "Place k3s-install.sh in repo root and run it"
deploy:
    @echo "kubectl apply -f manifests/"
clean:
    @echo "Remove generated artifacts"
EOF

# --- Документація ---
cat > "$OUTDIR/docs/index.md" <<'EOF'
# G.E.N.A. 4.0 Documentation
Quick links:
- Architecture: architecture.md
- Deployment: deployment.md
- Monitoring: monitoring.md
- Cert Manager: cert-manager.md
- Signal integration: signal.md
EOF

cat > "$OUTDIR/docs/deployment.md" <<'EOF'
# Deployment Guide
## Requirements
- Debian 12 / Ubuntu 22.04+
- Root access
- DNS records for Grafana/ArgoCD/Portainer
- GitHub Secrets configured

## Quick run
1. Place `k3s-install.sh` in repo root.
2. chmod +x k3s-install.sh && sudo ./k3s-install.sh
EOF

cat > "$OUTDIR/docs/monitoring.md" <<'EOF'
# Monitoring
Uses kube-prometheus-stack, Grafana, Alertmanager, Loki, Promtail.
See manifests/prom-values.yaml and manifests/loki-values.yaml.
EOF

cat > "$OUTDIR/docs/cert-manager.md" <<'EOF'
# Cert-Manager
Install via Helm, create Cloudflare secret, apply manifests/clusterissuer.yaml.
EOF

cat > "$OUTDIR/docs/signal.md" <<'EOF'
# Signal Integration
Add your signal_main.py into manifests/signal-adapter.yaml ConfigMap.
Security: avoid hostPath in production, use PVC.
EOF

cat > "$OUTDIR/docs/architecture.md" <<'EOF'
# Architecture
See docs/mermaid/cluster-architecture.md and infra-levels.md
EOF

# --- Mermaid diagrams ---
cat > "$OUTDIR/docs/mermaid/cluster-architecture.md" <<'EOF'
```mermaid
graph TD
  User((Користувач)) --> CF[Cloudflare DNS]
  CF --> Ingress[Ingress NGINX]
  subgraph "K3s Cluster 'Гена 3.0'"
    Ingress --> Grafana
    Prometheus -.-> NodeExporter
    Prometheus --> Grafana
    Promtail --> Loki
    Loki --> Grafana
    Prometheus --> Alertmanager
    Alertmanager --> SignalBot
    ArgoCD --> Apps
    CertManager --> Ingress
  end
  SignalBot --> Signal
  Apps --> Mikrotik
EOF

cat > "$OUTDIR/docs/mermaid/infra-levels.md" <<'EOF'
graph TD
  subgraph "Фізичний рівень"
    Hardware --> OS
    OS --> Firewall
  end
  subgraph "Orchestration"
    K3s --> CoreDNS
    K3s --> LocalPath
    K3s --> IngressNginx
  end
  subgraph "Services"
    Prom --> Grafana
    Prom --> Loki
    GitLab --> SQL
    API --> SQL
  end
EOF

# manifests/prom-values.yaml
cat > "$OUTDIR/manifests/prom-values.yaml" <<'EOF'
grafana:
  enabled: true
  adminPassword: "${GRAFANA_ADMIN_PASSWORD}"
EOF

# manifests/loki-values.yaml
cat > "$OUTDIR/manifests/loki-values.yaml" <<'EOF'
loki:
  deploymentMode: SingleBinary
EOF

cat > "$OUTDIR/manifests/clusterissuer.yaml" <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
name: ${LE_ISSUER_NAME}
spec:
acme:
server: ${LE_SERVER_URL}
email: ${USER_EMAIL}
EOF

cat > "$OUTDIR/manifests/signal-adapter.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
name: signal-adapter-code
namespace: monitoring
data:
main.py: |
# PLACEHOLDER: add your signal_main.py here
EOF

cat > "$OUTDIR/manifests/ingresses.yaml" <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
name: grafana-ingress
spec:
rules:
- host: ${GRAFANA_HOST}
EOF

cat > "$OUTDIR/ci/github-actions-deploy.yml" <<'EOF'
name: Deploy
on: [push]
jobs:
deploy:
runs-on: ubuntu-latest
steps:
- uses: actions/checkout@v4
- run: kubectl apply -f manifests/
EOF

echo "✅ Репозиторій створено у $OUTDIR"
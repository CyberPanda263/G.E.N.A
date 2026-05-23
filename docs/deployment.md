# Deployment Guide

## Requirements
- Debian 12 or Ubuntu 22.04+
- Root access
- Public DNS for Grafana / ArgoCD / Portainer (if used)
- GitHub Secrets configured for CI

## Environment variables (required)
- USER_EMAIL
- SIGNAL_NUMBER
- SIGNAL_RECIPIENTS
- WEBHOOK_TOKEN
- GRAFANA_HOST
- ARGOCD_HOST
- GRAFANA_ADMIN_PASSWORD
- CF_API_TOKEN

## Quick run (interactive)
1. Make script executable:
   ```bash
   chmod +x k3s-install.sh
   sudo ./k3s-install.sh

Manual steps summary
System prep, SSH hardening, UFW, Fail2Ban

Install K3s, configure kubeconfig

Install Helm and add repos

Create namespaces and PodSecurity labels

Install ingress-nginx, cert-manager, metrics-server

Install monitoring stack (Prometheus + Grafana + Alertmanager)

Install Loki + Promtail

Deploy Signal adapter and authorize via QR

Install Portainer (agent or server) and ArgoCD


---

#### manifests/prom-values.yaml
```yaml
grafana:
  enabled: true
  adminPassword: "${GRAFANA_ADMIN_PASSWORD}"
  livenessProbe:
    initialDelaySeconds: 120
    failureThreshold: 20
  readinessProbe:
    initialDelaySeconds: 60
    failureThreshold: 20
  persistence:
    enabled: true
    size: 5Gi
  resources:
    requests:
      cpu: 50m
      memory: 100Mi
    limits:
      cpu: 200m
      memory: 256Mi

prometheus:
  prometheusSpec:
    retention: ${PROM_RETENTION}
    scrapeInterval: 60s
    resources:
      requests:
        cpu: 150m
        memory: 400Mi
      limits:
        cpu: 500m
        memory: 1Gi
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 15Gi

alertmanager:
  enabled: true
  alertmanagerSpec:
    replicas: 1
  config:
    global:
      resolve_timeout: 5m
    route:
      group_by: ['namespace', 'alertname']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 12h
      receiver: 'signal-adapter'
      routes:
        - receiver: 'blackhole'
          matchers:
            - alertname =~ "InfoInhibitor|Watchdog"
    receivers:
      - name: 'blackhole'
      - name: 'signal-adapter'
        webhook_configs:
          - url: http://signal-adapter-service.monitoring.svc.cluster.local:8000/webhook
            send_resolved: true
            http_config:
              authorization:
                credentials: "${WEBHOOK_TOKEN}"

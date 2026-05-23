# Pre-deploy Checklist
- DNS: A/CAA records for GRAFANA_HOST, ARGOCD_HOST, PORTAINER_HOST.
- Ports: 22, 80, 443, 6443, 9090 reachable.
- Secrets: CF_API_TOKEN, WEBHOOK_TOKEN, GRAFANA_ADMIN_PASSWORD, USER_EMAIL, SIGNAL_NUMBER, SIGNAL_RECIPIENTS set in GitHub Secrets or Vault.
- Backups: PVC backups for Prometheus, Loki, GitLab, MS SQL.

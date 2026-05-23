# G.E.N.A. 4.0 — GitOps & Engineering Network Assistant

**Коротко**  
Enterprise hardened single‑node K3s platform (Debian 12 / Ubuntu 22.04+). Моніторинг, логування, алерти через Signal, ArgoCD GitOps, Cert‑Manager + Cloudflare DNS, Portainer.

**Швидкий старт**
1. Клонувати репозиторій.
2. Налаштувати GitHub Secrets: CF_API_TOKEN, WEBHOOK_TOKEN, GRAFANA_ADMIN_PASSWORD, USER_EMAIL, SIGNAL_NUMBER, SIGNAL_RECIPIENTS, ARGOCD_HOST, GRAFANA_HOST.
3. Додати ваш основний інсталер `k3s-install.sh` у корінь.
4. Запустити `sudo ./k3s-install.sh` або слідувати `docs/deployment.md`.

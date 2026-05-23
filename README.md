# 🚀 G.E.N.A. (GitOps & Engineering Network Assistant) v4.0.0

![K3s](https://img.shields.io/badge/k3s-v1.31.6-blue?logo=kubernetes)
![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04+-orange?logo=ubuntu)
![Debian](https://img.shields.io/badge/Debian-12-red?logo=debian)
![ArgoCD](https://img.shields.io/badge/ArgoCD-GitOps-green?logo=argo)
![Prometheus](https://img.shields.io/badge/Monitoring-Prometheus_|_Loki-E6522C?logo=prometheus)

**G.E.N.A.** — це автоматизований bash-скрипт для розгортання захищеної, готової до production (Enterprise Hardened) single-node інфраструктури на базі **K3s**. Платформа включає повний стек моніторингу, автоматичне управління SSL-сертифікатами, GitOps (ArgoCD) та унікальну систему маршрутизації алертів у месенджер **Signal**.

Ідеально підходить для розгортання pet-проєктів, edge-серверів, локальних лабораторій та закритих мереж.

---

## 🏗 Архітектура платформи

Схема нижче демонструє взаємодію компонентів всередині кластера та їх зв'язок із зовнішнім світом. *(GitHub автоматично рендерить цю схему)*.

```mermaid
graph TD
    User((🌐 Користувач / Адмін)) -->|HTTPS| DNS[Cloudflare DNS]
    DNS -->|Трафік| UFW[UFW Firewall + Fail2Ban]
    
    subgraph Host OS [Debian 12 / Ubuntu 22.04 Server]
        UFW --> Cockpit[Cockpit UI: 9090]
        UFW --> K3s[K3s Kubernetes Cluster]
        
        subgraph K3s Cluster
            K3s --> Ingress[Ingress NGINX]
            
            Ingress -->|Grafana| Grafana[Grafana UI]
            Ingress -->|ArgoCD| ArgoCD[ArgoCD Server]
            Ingress -->|Portainer| Portainer[Portainer Server]
            
            CertManager[Cert-Manager] -.->|DNS-01 Challenge| DNS
            
            subgraph Monitoring & Alerting
                Metrics[Metrics Server] --> Prom[Prometheus]
                Promtail --> Loki[Loki]
                Loki --> Grafana
                Prom --> Grafana
                
                Prom --> Alertmanager[Alertmanager]
                Alertmanager -->|Webhook| SignalAdapter[Python Signal Adapter]
                SignalAdapter -->|API| SignalCLI[Signal REST API]
            end
        end
    end
    
    SignalCLI -->|Push повідомлення| SignalApp((📱 Додаток Signal))
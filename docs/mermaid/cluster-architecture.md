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

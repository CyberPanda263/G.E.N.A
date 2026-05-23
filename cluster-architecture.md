graph TD
  classDef user fill:#7fb3ff,stroke:#1f6feb,color:#000;
  classDef network fill:#ffb86b,stroke:#d97706,color:#000;
  classDef ingress fill:#7ee787,stroke:#2d6a4f,color:#000;
  classDef monitoring fill:#ffd166,stroke:#f59e0b,color:#000;
  classDef apps fill:#f4a261,stroke:#e76f51,color:#000;

  User((Користувач)):::user --> CF[Cloudflare DNS]:::network
  CF --> Ingress[Ingress NGINX]:::ingress

  subgraph "K3s Cluster 'Гена 3.0'"
    Ingress --> AppService[ASP.NET / GitLab / Portainer]:::apps
    Ingress --> Grafana[Grafana]:::monitoring
    Prometheus[Prometheus]:::monitoring -.-> NodeExporter[Node Exporter]:::monitoring
    Prometheus --> Grafana
    Promtail[Promtail]:::monitoring --> Loki[Loki]:::monitoring
    Loki --> Grafana
    Prometheus --> Alertmanager[Alertmanager]:::monitoring
    Alertmanager -->|Webhook| SignalBot[Signal Adapter]:::network
    ArgoCD[ArgoCD]:::apps -->|Deploys| Apps[Apps: SQL, .NET, GitLab]:::apps
    CertManager[Cert-Manager]:::ingress -->|SSL| Ingress
  end

  SignalBot -->|API| Signal[Signal Messenger]:::network
  Apps -->|Webhook| Mikrotik[MikroTik / Network]:::network

```mermaid
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



#### infra-levels.md (Mermaid)
```markdown
```mermaid
graph TD
  classDef metal fill:#6b7280,stroke:#374151,color:#fff;
  classDef orchestration fill:#0ea5a4,stroke:#064e3b,color:#fff;
  classDef services fill:#f97316,stroke:#7c2d12,color:#fff;
  classDef monitor fill:#f59e0b,stroke:#92400e,color:#000;
  classDef apps fill:#ef4444,stroke:#7f1d1d,color:#fff;

  subgraph "Фізичний рівень Bare Metal VM"
    Hardware[CPU RAM SSD]:::metal
    OS[Debian 12 Ubuntu 22.04]:::metal
    Firewall[UFW Fail2Ban]:::metal
  end

  subgraph "Рівень Orchestration K3s"
    K3s[K3s Runtime]:::orchestration
    K3s --> CoreDNS[CoreDNS]:::orchestration
    K3s --> LocalPath[Local Path Provisioner]:::orchestration
    K3s --> IngressNginx[Ingress Nginx Controller]:::orchestration
  end

  subgraph "Рівень Services"
    subgraph "Monitoring Namespace"
      Prom[Prometheus]:::monitor
      Grafana[Grafana]:::monitor
      Loki[Loki]:::monitor
    end
    subgraph "Apps Namespace"
      GitLab[GitLab CE]:::apps
      SQL[MS SQL Server]:::apps
      API[ASP.NET Core API]:::apps
    end
  end

  Hardware --> OS
  OS --> K3s
  K3s --> Prom
  K3s --> GitLab
  LocalPath -->|Data Persistence| SQL
  LocalPath -->|Data Persistence| GitLab

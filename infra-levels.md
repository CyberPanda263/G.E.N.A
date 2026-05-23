graph TD
  classDef metal fill:#6b7280,stroke:#374151,color:#fff;
  classDef orchestration fill:#0ea5a4,stroke:#064e3b,color:#fff;
  classDef services fill:#f97316,stroke:#7c2d12,color:#fff;
  classDef monitor fill:#f59e0b,stroke:#92400e,color:#000;
  classDef apps fill:#ef4444,stroke:#7f1d1d,color:#fff;

  subgraph "Фізичний рівень Bare Metal VM"
    Hardware[CPU RAM SSD]:::metal
    OS[Debian 12 / Ubuntu 22.04]:::metal
    Firewall[UFW + Fail2Ban]:::metal
  end

  subgraph "Рівень Orchestration (K3s)"
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

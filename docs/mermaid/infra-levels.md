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

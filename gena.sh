#!/bin/bash

set -Eeuo pipefail

#################################################################
# G.E.N.A. - GitOps & Engineering Network Assistant             #
# Version: 4.0.0 (Interactive Edition)                          #
# Purpose: Cluster monitoring and automated alert management    #
# Enterprise Hardened Single Node K3s Platform                  #
# Debian 12 / Ubuntu 22.04+                                     #
# Optimized for Production / Closed Networks                    #
#################################################################

# =========================================================
# COLORS & LOGGING
# =========================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

if [[ "$EUID" -ne 0 ]]; then
  error "Run as root"
fi

# =========================================================
# INTERACTIVE PROMPTS (SSL & PORTAINER)
# =========================================================

echo -e "${YELLOW}=================================================${NC}"
echo -e "${BLUE}Оберіть режим Let's Encrypt (SSL):${NC}"
echo "1) Staging (Тестовий - без лімітів API, для розробки)"
echo "2) Production (Бойовий - ліміт 5/тиждень, довірені сертифікати)"
read -p "Ваш вибір [1 або 2, за замовчуванням 1]: " LE_CHOICE
LE_CHOICE=${LE_CHOICE:-1}

if [ "$LE_CHOICE" == "2" ]; then
  LE_ISSUER_NAME="letsencrypt-prod"
  LE_SERVER_URL="https://acme-v02.api.letsencrypt.org/directory"
  log "Обрано Production Let's Encrypt."
else
  LE_ISSUER_NAME="letsencrypt-staging"
  LE_SERVER_URL="https://acme-staging-v02.api.letsencrypt.org/directory"
  log "Обрано Staging Let's Encrypt."
fi

echo -e "${YELLOW}=================================================${NC}"
echo -e "${BLUE}Оберіть тип встановлення Portainer:${NC}"
echo "1) Portainer Agent (Тільки клієнт для існуючого сервера)"
echo "2) Portainer Server (Повноцінний сервер з UI та Ingress)"
read -p "Ваш вибір [1 або 2, за замовчуванням 1]: " PORTAINER_CHOICE
PORTAINER_CHOICE=${PORTAINER_CHOICE:-1}

PORTAINER_HOST="${PORTAINER_HOST:-""}"

if [ "$PORTAINER_CHOICE" == "2" ]; then
  log "Обрано Portainer Server."
  if [ -z "$PORTAINER_HOST" ]; then
    read -p "Введіть домен для Portainer (напр. portainer.binaro.uno): " PORTAINER_HOST
    if [ -z "$PORTAINER_HOST" ]; then
      error "Домен PORTAINER_HOST є обов'язковим для встановлення Server!"
    fi
  fi
else
  log "Обрано Portainer Agent."
fi
echo -e "${YELLOW}=================================================${NC}"

# =========================================================
# REQUIRED ENV
# =========================================================

: "${USER_EMAIL:?Set USER_EMAIL}"

: "${SIGNAL_NUMBER:?Set SIGNAL_NUMBER}"
: "${SIGNAL_RECIPIENTS:?Set SIGNAL_RECIPIENTS}"
: "${WEBHOOK_TOKEN:?Set WEBHOOK_TOKEN}"

: "${GRAFANA_HOST:?Set GRAFANA_HOST}"
: "${ARGOCD_HOST:?Set ARGOCD_HOST}"

: "${GRAFANA_ADMIN_PASSWORD:?Set GRAFANA_ADMIN_PASSWORD}"
: "${CF_API_TOKEN:?Set CF_API_TOKEN}"

# =========================================================
# OPTIONAL ENV
# =========================================================

K3S_VERSION="${K3S_VERSION:-v1.31.6+k3s1}"
K3S_INSTALL_OPTS="${K3S_INSTALL_OPTS:---disable traefik --disable servicelb --disable metrics-server}"

PROM_RETENTION="${PROM_RETENTION:-7d}"
LOKI_RETENTION="${LOKI_RETENTION:-168h}"

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME=$(eval echo "~$TARGET_USER")

# =========================================================
# 1. SYSTEM PREP
# =========================================================

log "Preparing system..."

apt update

apt install -y \
  curl \
  wget \
  git \
  jq \
  unzip \
  ca-certificates \
  apt-transport-https \
  gnupg \
  lsb-release \
  python3 \
  python3-pip \
  ufw \
  fail2ban \
  cockpit

systemctl enable --now cockpit.socket

# =========================================================
# 2. SSH HARDENING + FIREWALL
# =========================================================

log "Hardening SSH..."

sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config

systemctl restart ssh || systemctl restart sshd || true

log "Configuring firewall..."

ufw default allow forward
ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 6443/tcp
ufw allow 9090/tcp

# K3s / Flannel interfaces
ufw allow in on cni0
ufw allow out on cni0
ufw allow in on flannel.1
ufw allow out on flannel.1

ufw --force enable

cat >/etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
backend = systemd
maxretry = 5
bantime = 1h
EOF

systemctl enable --now fail2ban

# =========================================================
# 3. SYSCTL
# =========================================================

log "Applying kernel parameters..."

swapoff -a || true
sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab || true

cat >/etc/sysctl.d/99-kubernetes.conf <<EOF
vm.swappiness=10
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=512
EOF

sysctl --system

# =========================================================
# 4. DAILY CLEANUP
# =========================================================

log "Configuring daily cleanup..."

cat >/etc/cron.daily/k3s-cleanup <<'EOF'
#!/bin/bash
k3s crictl rmi --prune || true
EOF

chmod +x /etc/cron.daily/k3s-cleanup

# =========================================================
# 5. INSTALL K3S
# =========================================================

log "Installing K3s ${K3S_VERSION}..."

curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="${K3S_VERSION}" \
  sh -s - ${K3S_INSTALL_OPTS}

# =========================================================
# 6. K3S OOM PROTECTION
# =========================================================

log "Applying K3s OOM protection..."

mkdir -p /etc/systemd/system/k3s.service.d

cat >/etc/systemd/system/k3s.service.d/override.conf <<EOF
[Service]
OOMScoreAdjust=-900
EOF

systemctl daemon-reload
systemctl restart k3s

# =========================================================
# 7. KUBECONFIG
# =========================================================

NODE_IP=$(ip route get 1 | awk '{print $7; exit}')

mkdir -p "${TARGET_HOME}/.kube"

cp /etc/rancher/k3s/k3s.yaml "${TARGET_HOME}/.kube/config"

sed -i "s/127.0.0.1/${NODE_IP}/" "${TARGET_HOME}/.kube/config"

chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.kube"

chmod 600 "${TARGET_HOME}/.kube/config"

export KUBECONFIG="${TARGET_HOME}/.kube/config"

log "Waiting for node registration..."

while [ -z "$(kubectl get nodes -o name 2>/dev/null)" ]; do
  sleep 2
done

kubectl wait --for=condition=Ready nodes --all --timeout=180s

# =========================================================
# 8. HELM
# =========================================================

if ! command -v helm &>/dev/null; then
  log "Installing Helm..."
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# =========================================================
# 9. NAMESPACES
# =========================================================

log "Creating namespaces..."

for ns in \
  monitoring \
  ingress-nginx \
  cert-manager \
  argocd \
  portainer
do
  kubectl create namespace "$ns" \
    --dry-run=client -o yaml | kubectl apply -f -
done

# =========================================================
# 10. POD SECURITY
# =========================================================

log "Applying Pod Security labels..."

kubectl label namespace monitoring \
  pod-security.kubernetes.io/enforce=privileged \
  --overwrite

# =========================================================
# 11. HELM REPOS
# =========================================================

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add jetstack https://charts.jetstack.io
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo add portainer https://portainer.github.io/k8s

helm repo update

# =========================================================
# 12. INGRESS NGINX
# =========================================================

log "Installing ingress-nginx..."

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --set controller.kind=DaemonSet \
  --set controller.hostNetwork=true \
  --set controller.dnsPolicy=ClusterFirstWithHostNet \
  --set controller.reportNodeInternalIp=true \
  --set controller.replicaCount=1 \
  --set controller.resources.requests.cpu=100m \
  --set controller.resources.requests.memory=128Mi \
  --set controller.resources.limits.cpu=500m \
  --set controller.resources.limits.memory=512Mi

# =========================================================
# 13. METRICS SERVER
# =========================================================

log "Installing metrics-server..."

helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system \
  --set args="{--kubelet-insecure-tls}"

# =========================================================
# 14. CERT MANAGER
# =========================================================

log "Installing cert-manager..."

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --set installCRDs=true

kubectl wait \
  --for=condition=Established \
  crd/certificates.cert-manager.io \
  --timeout=120s

kubectl wait \
  --for=condition=Available \
  deployment/cert-manager-webhook \
  -n cert-manager \
  --timeout=120s

# =========================================================
# 15. CLOUDFLARE SECRET
# =========================================================

kubectl create secret generic cloudflare-api-token-secret \
  -n cert-manager \
  --from-literal=api-token="${CF_API_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

# =========================================================
# 16. CLUSTER ISSUER (DYNAMIC)
# =========================================================

log "Deploying ClusterIssuer (${LE_ISSUER_NAME})..."

cat >/tmp/clusterissuer.yaml <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${LE_ISSUER_NAME}
spec:
  acme:
    server: ${LE_SERVER_URL}
    email: ${USER_EMAIL}
    privateKeySecretRef:
      name: ${LE_ISSUER_NAME}-key
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token-secret
              key: api-token
EOF

kubectl apply -f /tmp/clusterissuer.yaml

# =========================================================
# 17. PROMETHEUS + GRAFANA
# =========================================================

log "Installing monitoring stack..."

cat >/tmp/prom-values.yaml <<EOF
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
EOF

helm upgrade --install monitoring \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  -f /tmp/prom-values.yaml

# =========================================================
# 18. LOKI
# =========================================================

log "Installing Loki..."

cat >/tmp/loki-values.yaml <<EOF
loki:
  deploymentMode: SingleBinary
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
  schemaConfig:
    configs:
      - from: "2024-01-01"
        object_store: filesystem
        store: tsdb
        schema: v13
        index:
          prefix: index_
          period: 24h
  limits_config:
    retention_period: ${LOKI_RETENTION}
singleBinary:
  replicas: 1
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 300m
      memory: 512Mi
persistence:
  enabled: true
  size: 10Gi
read:
  replicas: 0
write:
  replicas: 0
backend:
  replicas: 0
EOF

helm upgrade --install loki grafana/loki \
  --namespace monitoring \
  -f /tmp/loki-values.yaml

# =========================================================
# 19. PROMTAIL
# =========================================================

log "Installing Promtail..."

helm upgrade --install promtail grafana/promtail \
  --namespace monitoring \
  --set config.clients[0].url=http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push \
  --set resources.limits.memory=128Mi

# =========================================================
# 19.5 SIGNAL AUTHENTICATION
# =========================================================

log "Initializing Signal authentication..."

SIGNAL_DIR="/var/lib/signal-cli"
mkdir -p "$SIGNAL_DIR"
chmod 777 "$SIGNAL_DIR" 

if ! grep -q "$SIGNAL_NUMBER" <(ls -1 "$SIGNAL_DIR/data" 2>/dev/null || true); then
    log "Signal не авторизовано. Запуск фонового Pod для генерації QR-посилання..."
    
    if ! command -v qrencode &> /dev/null; then
        apt-get update -qq && apt-get install -y qrencode -qq
    fi

    kubectl delete pod signal-linker -n monitoring --ignore-not-found 2>/dev/null || true
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: signal-linker
  namespace: monitoring
spec:
  restartPolicy: Never
  containers:
  - name: linker
    image: bbernhard/signal-cli-rest-api:latest
    command: ["signal-cli", "--config", "/home/.local/share/signal-cli", "link", "--name", "G.E.N.A.-Cluster"]
    volumeMounts:
    - name: signal-data
      mountPath: /home/.local/share/signal-cli
  volumes:
  - name: signal-data
    hostPath:
      path: "${SIGNAL_DIR}"
      type: DirectoryOrCreate
EOF

    log "Чекаємо завантаження образу та генерації посилання..."
    
    QR_LINK=""
    for i in {1..60}; do
        QR_LINK=$(kubectl logs signal-linker -n monitoring 2>/dev/null | grep -oE "sgnl://[^ ]+" | tail -n 1 || true)
        if [[ -n "$QR_LINK" ]]; then
            break
        fi
        sleep 3
    done

    if [[ -z "$QR_LINK" ]]; then
        kubectl delete pod signal-linker -n monitoring --ignore-not-found 2>/dev/null || true
        error "Не вдалося отримати QR-посилання."
    fi

    echo
    echo -e "${YELLOW}================ SIGNAL QR AUTH =================${NC}"
    echo "Відскануйте цей QR-код у додатку Signal:"
    echo
    echo "$QR_LINK" | qrencode -t UTF8
    echo
    echo "Текстове посилання: $QR_LINK"
    echo -e "${YELLOW}=================================================${NC}"
    echo

    log "Очікування підтвердження на телефоні..."
    
    SUCCESS=0
    for i in {1..24}; do
        POD_STATUS=$(kubectl get pod signal-linker -n monitoring -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [[ "$POD_STATUS" == "Succeeded" ]]; then
            SUCCESS=1
            break
        fi
        sleep 5
    done

    kubectl delete pod signal-linker -n monitoring --ignore-not-found 2>/dev/null || true

    if [ $SUCCESS -eq 1 ]; then
        log "Signal успішно авторизовано ✔"
    else
        error "Тайм-аут очікування сканування."
    fi
else
    log "Signal вже авторизовано."
fi

# =========================================================
# 20. SIGNAL ADAPTER
# =========================================================

log "Deploying Signal REST API & Python Translator..."

cat >/tmp/signal_main.py <<'PY'
import json
import os
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from datetime import datetime

TOKEN = os.getenv("WEBHOOK_TOKEN")
SIGNAL_API_URL = os.getenv("SIGNAL_API_URL", "http://127.0.0.1:8080")
SIGNAL_NUMBER = os.getenv("SIGNAL_NUMBER")
SIGNAL_RECIPIENTS = [r.strip() for r in os.getenv("SIGNAL_RECIPIENTS", "").split(",") if r.strip()]

def send_to_signal(message):
    for recipient in SIGNAL_RECIPIENTS:
        payload = {"number": SIGNAL_NUMBER, "recipients": [recipient], "message": message}
        try:
            req = urllib.request.Request(
                f"{SIGNAL_API_URL}/v2/send",
                data=json.dumps(payload).encode(),
                headers={"Content-Type": "application/json"},
                method="POST"
            )
            urllib.request.urlopen(req, timeout=10)
        except Exception as e:
            print(f"Signal send error: {e}")

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        if self.path != "/webhook":
            self.send_response(404)
            self.end_headers()
            return

        auth = self.headers.get("Authorization")
        if auth != f"Bearer {TOKEN}":
            self.send_response(401)
            self.end_headers()
            return

        length = int(self.headers.get("Content-Length", 0))
        try:
            body = self.rfile.read(length)
            data = json.loads(body.decode())
        except Exception:
            self.send_response(400)
            self.end_headers()
            return

        status = data.get("status", "firing")
        for alert in data.get("alerts", []):
            labels = alert.get("labels", {})
            annotations = alert.get("annotations", {})
            severity = labels.get("severity", "info").upper()

            if status == "resolved":
                emoji = "🟢"
            elif severity == "CRITICAL":
                emoji = "🚨"
            else:
                emoji = "⚠️"

            text = "\n".join([
                f"{emoji} {labels.get('alertname', 'Alert')}",
                f"Severity: {severity}",
                f"Namespace: {labels.get('namespace', 'default')}",
                f"Description: {annotations.get('description', 'No description')}",
                f"Time: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"
            ])
            send_to_signal(text)

        self.send_response(200)
        self.end_headers()

if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
PY

kubectl create configmap signal-adapter-code \
  -n monitoring \
  --from-file=main.py=/tmp/signal_main.py \
  --dry-run=client -o yaml | kubectl apply -f -

cat >/tmp/signal-adapter.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: signal-adapter
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: signal-adapter
  template:
    metadata:
      labels:
        app: signal-adapter
    spec:
      containers:
        - name: python-adapter
          image: python:3.11-slim
          command: ["python", "/app/main.py"]
          ports: [{ containerPort: 8000 }]
          env:
            - name: SIGNAL_API_URL
              value: "http://127.0.0.1:8080"
            - name: SIGNAL_NUMBER
              value: "${SIGNAL_NUMBER}"
            - name: SIGNAL_RECIPIENTS
              value: "${SIGNAL_RECIPIENTS}"
            - name: WEBHOOK_TOKEN
              value: "${WEBHOOK_TOKEN}"
          resources:
            requests: { cpu: 10m, memory: 32Mi }
            limits: { cpu: 100m, memory: 128Mi }
          volumeMounts:
            - name: code-volume
              mountPath: /app

        - name: signal-rest-api
          image: bbernhard/signal-cli-rest-api:latest
          env:
            - name: MODE
              value: "native"
            - name: SIGNAL_CLI_OPTS
              value: "--config /home/.local/share/signal-cli"
          ports: [{ containerPort: 8080 }]
          resources:
            requests: { cpu: 50m, memory: 128Mi }
            limits: { cpu: 300m, memory: 512Mi }
          volumeMounts:
            - name: signal-data
              mountPath: /home/.local/share/signal-cli
      volumes:
        - name: code-volume
          configMap: { name: signal-adapter-code }
        - name: signal-data
          hostPath:
            path: "$SIGNAL_DIR"
            type: DirectoryOrCreate
---
apiVersion: v1
kind: Service
metadata:
  name: signal-adapter-service
  namespace: monitoring
spec:
  ports: [{ port: 8000, targetPort: 8000 }]
  selector: { app: signal-adapter }
EOF

kubectl apply -f /tmp/signal-adapter.yaml

# =========================================================
# 21. PORTAINER (SERVER OR AGENT)
# =========================================================

if [ "$PORTAINER_CHOICE" == "2" ]; then
  log "Installing Portainer Server..."
  helm upgrade --install portainer portainer/portainer \
      --namespace portainer \
      --set tls.force=false \
      --set resources.requests.cpu=50m \
      --set resources.requests.memory=128Mi \
      --set resources.limits.cpu=200m \
      --set resources.limits.memory=256Mi
else
  log "Installing Portainer Agent Only..."
  kubectl apply -n portainer -f https://downloads.portainer.io/ce2-21/portainer-agent-k8s-nodeport.yaml
fi

# =========================================================
# 22. ARGOCD
# =========================================================

log "Installing ArgoCD..."

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --set server.resources.requests.cpu=50m \
  --set server.resources.requests.memory=128Mi \
  --set server.resources.limits.cpu=300m \
  --set server.resources.limits.memory=512Mi

log "Waiting for ArgoCD deployment rollout..."

kubectl rollout status deployment/argocd-server -n argocd --timeout=300s
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=300s

log "ArgoCD components rolled out successfully."

# =========================================================
# 23. INGRESS
# =========================================================

log "Configuring ingress..."

cat >/tmp/ingresses.yaml <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana-ingress
  namespace: monitoring
  annotations:
    cert-manager.io/cluster-issuer: ${LE_ISSUER_NAME}
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - ${GRAFANA_HOST}
      secretName: grafana-tls
  rules:
    - host: ${GRAFANA_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: monitoring-grafana
                port:
                  number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-ingress
  namespace: argocd
  annotations:
    cert-manager.io/cluster-issuer: ${LE_ISSUER_NAME}
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - ${ARGOCD_HOST}
      secretName: argocd-tls
  rules:
    - host: ${ARGOCD_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 443
EOF

if [ "$PORTAINER_CHOICE" == "2" ]; then
cat >>/tmp/ingresses.yaml <<EOF
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: portainer-ingress
  namespace: portainer
  annotations:
    cert-manager.io/cluster-issuer: ${LE_ISSUER_NAME}
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - ${PORTAINER_HOST}
      secretName: portainer-tls
  rules:
    - host: ${PORTAINER_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: portainer
                port:
                  number: 9000
EOF
fi

kubectl apply -f /tmp/ingresses.yaml

# =========================================================
# 24. ROLLOUT CHECKS
# =========================================================

log "Verifying rollout status..."

kubectl rollout status daemonset/ingress-nginx-controller \
  -n ingress-nginx \
  --timeout=120s || true

kubectl rollout status deployment/signal-adapter \
  -n monitoring \
  --timeout=120s || true

if [ "$PORTAINER_CHOICE" == "2" ]; then
  kubectl rollout status deployment/portainer -n portainer --timeout=90s || true
else
  kubectl wait --for=condition=ready pod -l app=portainer-agent -n portainer --timeout=180s || true
fi

# =========================================================
# 25. ARGO PASSWORD
# =========================================================

log "Waiting for ArgoCD admin secret..."

for i in {1..60}; do
  if kubectl get secret argocd-initial-admin-secret -n argocd >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

ARGOCD_PWD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d 2>/dev/null || echo "Can't retrieve (already changed)")

# =========================================================
# DONE
# =========================================================

echo
echo -e "${GREEN}✅ Платформа 'G.E.N.A. 4.0' успішно розгорнута!${NC}"
echo
echo -e "${BLUE}Cockpit:${NC}  https://${NODE_IP}:9090"
echo -e "${BLUE}Grafana:${NC} https://${GRAFANA_HOST} (User: admin, Pass: ${GRAFANA_ADMIN_PASSWORD})"
echo -e "${BLUE}ArgoCD:${NC}  https://${ARGOCD_HOST} (User: admin, Pass: ${ARGOCD_PWD})"

if [ "$PORTAINER_CHOICE" == "2" ]; then
  echo -e "${BLUE}Portainer:${NC} https://${PORTAINER_HOST} (User: admin, Set pass on first login)"
  echo
  echo -e "${GREEN}✅ Portainer Server встановлений.${NC}"
else
  PORTAINER_NODE_IP=$(kubectl get nodes -o jsonpath="{.items[0].status.addresses[?(@.type=='InternalIP')].address}")
  PORTAINER_NODE_PORT=$(kubectl get svc -n portainer -o jsonpath="{.items[0].spec.ports[0].nodePort}" 2>/dev/null || echo "30778")
  echo
  echo -e "${GREEN}✅ Portainer Agent встановлений.${NC}"
  echo -e "${YELLOW}================ PORTAINER AGENT =================${NC}"
  echo -e "${BLUE}Node IP:${NC}        ${PORTAINER_NODE_IP}"
  echo -e "${BLUE}Agent Endpoint:${NC} tcp://${PORTAINER_NODE_IP}:${PORTAINER_NODE_PORT}"
  echo -e "${YELLOW}==================================================${NC}"
fi

echo
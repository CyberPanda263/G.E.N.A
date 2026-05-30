#!/bin/bash

set -Eeuo pipefail

#################################################################
# G.E.N.A. - GitOps & Engineering Network Assistant             #
# Version: 6.0.0 (Native MinIO + Tekton SSL Unified Fix)        #
# Purpose: Cluster monitoring, CI/CD, alert management          #
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
  error "Будь ласка, запустіть скрипт від імені root (sudo)"
fi

NODE_IP=$(ip route get 1 | awk '{print $7; exit}')

# =========================================================
# AUTOMATIC ENV LOADING
# =========================================================

if [ -f .env ]; then
  log "Знайдено файл .env. Автоматично завантажуємо конфігурацію..."
  set -a
  source .env
  set +a
else
  warn "Файл .env не знайдено в поточній директорії! Скрипт використовуватиме експортовані змінні."
fi

# =========================================================
# БАНЕР G.E.N.A.
# =========================================================
echo ""
echo -e "${BLUE}#################################################################${NC}"
echo -e "${BLUE}# G.E.N.A. - GitOps & Engineering Network Assistant             #${NC}"
echo -e "${BLUE}# Version: 6.0.0 (Native MinIO + Tekton SSL Unified Fix)        #${NC}"
echo -e "${BLUE}# Purpose: Cluster monitoring, CI/CD, alert management          #${NC}"
echo -e "${BLUE}# Enterprise Hardened Single Node K3s Platform                  #${NC}"
echo -e "${BLUE}# Debian 12 / Ubuntu 22.04+                                     #${NC}"
echo -e "${BLUE}# Optimized for Production / Closed Networks                    #${NC}"
echo -e "${BLUE}#################################################################${NC}"
echo ""

# =========================================================
# INTERACTIVE PROMPTS
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
echo "1) Portainer Agent (Тільки клієнт для існуюcego сервера)"
echo "2) Portainer Server (Повноцінний сервер з UI та Ingress)"
read -p "Ваш вибір [1 або 2, за замовчуванням 1]: " PORTAINER_CHOICE
PORTAINER_CHOICE=${PORTAINER_CHOICE:-1}

PORTAINER_HOST="${PORTAINER_HOST:-""}"

if [ "$PORTAINER_CHOICE" == "2" ]; then
  log "Обрано Portainer Server."
  if [ -z "$PORTAINER_HOST" ]; then
    read -p "Введіть домен для Portainer (напр. portainer.domain.com): " PORTAINER_HOST
    if [ -z "$PORTAINER_HOST" ]; then
      error "Домен PORTAINER_HOST є обов'язковим для встановлення Server!"
    fi
  fi
else
  log "Обрано Portainer Agent."
fi

echo -e "${YELLOW}=================================================${NC}"
echo -e "${BLUE}Оберіть систему резервного копіювання:${NC}"
echo "1) PBS Client (Копіює тільки файли, маніфести K8s не бекапить)"
echo "2) Velero (Стандартний: потребує зовнішній S3, напр. AWS S3 / R2)"
echo "3) Velero + In-Cluster MinIO (Повноцінний бекап на локальне S3-сховище)"
echo "4) Longhorn (Бекап тільки дисків із даними, без конфігурацій кластера)"
echo "5) Без Kubernetes backup (Тільки снепшоти всієї ВМ через Proxmox)"
read -p "Ваш вибір [1-5, за замовчуванням 5]: " BACKUP_CHOICE
BACKUP_CHOICE=${BACKUP_CHOICE:-5}

PBS_IP="${PBS_IP:-YOUR_PBS_IP}"
PBS_USER="${PBS_USER:-root@pam}"
PBS_DATASTORE="${PBS_DATASTORE:-backup}"

MINIO_ROOT_USER="${MINIO_ROOT_USER:-admin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-secret}"

VELERO_NAMESPACE="velero"
MINIO_HOST="${MINIO_HOST:-minio.binaro.uno}"
LONGHORN_UI="http://$NODE_IP:3000"

# =========================================================
# REQUIRED ENV VALIDATION
# =========================================================

log "Валідація обов'язкових параметрів оточення..."
: "${USER_EMAIL:?Set USER_EMAIL in .env}"
: "${SIGNAL_NUMBER:?Set SIGNAL_NUMBER in .env}"
: "${SIGNAL_RECIPIENTS:?Set SIGNAL_RECIPIENTS in .env}"
: "${WEBHOOK_TOKEN:?Set WEBHOOK_TOKEN in .env}"
: "${GRAFANA_HOST:?Set GRAFANA_HOST in .env}"
: "${ARGOCD_HOST:?Set ARGOCD_HOST in .env}"
: "${TEKTON_HOST:?Set TEKTON_HOST in .env}"
: "${GRAFANA_ADMIN_PASSWORD:?Set GRAFANA_ADMIN_PASSWORD in .env}"
: "${CF_API_TOKEN:?Set CF_API_TOKEN in .env}"

# =========================================================
# OPTIONAL ENV
# =========================================================

K3S_VERSION="${K3S_VERSION:-v1.31.6+k3s1}"
INSTALL_K3S_EXEC="server --disable traefik --disable servicelb --disable metrics-server"
PROM_RETENTION="${PROM_RETENTION:-7d}"
LOKI_RETENTION="${LOKI_RETENTION:-168h}"

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME=$(eval echo "~$TARGET_USER")

# =========================================================
# 1. SYSTEM PREP
# =========================================================

log "Preparing system..."
apt update
apt install -y curl wget git jq unzip ca-certificates apt-transport-https gnupg lsb-release python3 python3-pip ufw fail2ban cockpit
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
/usr/local/bin/crictl rmi --prune || true
/usr/local/bin/crictl rm -a || true
find /var/log/pods/ -type f -name "*.log" -mtime +2 -delete
apt-get clean
EOF
chmod +x /etc/cron.daily/k3s-cleanup

# =========================================================
# 5. K3S REGISTRIES CONFIG
# =========================================================

log "Configuring K3s containerd registries..."
mkdir -p /etc/rancher/k3s
cat >/etc/rancher/k3s/registries.yaml <<EOF
mirrors:
  "registry.registry.svc.cluster.local:5000":
    endpoint:
      - "http://registry.registry.svc.cluster.local:5000"
EOF

# =========================================================
# 6. INSTALL K3S
# =========================================================

log "Installing K3s ${K3S_VERSION}..."
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="${K3S_VERSION}" \
  INSTALL_K3S_EXEC="${INSTALL_K3S_EXEC}" \
  sh -

# =========================================================
# 7. K3S OOM PROTECTION
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
# 8. KUBECONFIG
# =========================================================

mkdir -p "${TARGET_HOME}/.kube"
cp /etc/rancher/k3s/k3s.yaml "${TARGET_HOME}/.kube/config"
sed -i "s/127.0.0.1/${NODE_IP}/" "${TARGET_HOME}/.kube/config"
chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.kube"
chmod 600 "${TARGET_HOME}/.kube/config"
export KUBECONFIG="${TARGET_HOME}/.kube/config"

log "Waiting for node registration..."
while [ -z "$(kubectl get nodes -o name 2>/dev/null)" ]; do sleep 2; done
kubectl wait --for=condition=Ready nodes --all --timeout=180s

# =========================================================
# 9. HELM & BACKUP TOOLS
# =========================================================

if ! command -v helm &>/dev/null; then
  log "Installing Helm..."
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

setup_pbs_client() {
  log "Installing Proxmox Backup Client..."
  apt update && apt install -y proxmox-backup-client || true
  cat >/etc/pbs-client.cfg <<EOF
PBS_REPOSITORY="${PBS_USER}@pbs@${PBS_IP}:${PBS_DATASTORE}"
EOF
}

setup_velero_standard() {
  log "Installing Velero (Standard Mode - Waiting for manual Provider config)..."
  helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
  helm repo update
  kubectl create namespace velero --dry-run=client -o yaml | kubectl apply -f -
  warn "Увага: Velero встановлено в базовому режимі. Необхідно налаштувати BackupStorageLocation!"
}

setup_velero_minio() {
  log "Installing In-Cluster MinIO & Velero (Native Manifest Mode)..."
  helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
  helm repo update

  # 1. Розгортання MinIO через нативний Deployment & Service (Уникаємо Bitnami шлюзів)
  kubectl create namespace minio --dry-run=client -o yaml | kubectl apply -f -
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: minio
spec:
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
      - name: minio
        image: quay.io/minio/minio:latest
        args: ["server", "/data", "--console-address", ":9090"]
        env:
        - name: MINIO_ROOT_USER
          value: "${MINIO_ROOT_USER}"
        - name: MINIO_ROOT_PASSWORD
          value: "${MINIO_ROOT_PASSWORD}"
        ports:
        - containerPort: 9000
        - containerPort: 9090
        volumeMounts:
        - name: minio-storage
          mountPath: /data
      volumes:
      - name: minio-storage
        hostPath:
          path: /var/lib/minio-data
          type: DirectoryOrCreate
---
apiVersion: v1
kind: Service
metadata:
  name: minio-service
  namespace: minio
spec:
  type: ClusterIP
  ports:
    - port: 9000
      targetPort: 9000
      name: api
    - port: 9090
      targetPort: 9090
      name: console
  selector:
    app: minio
EOF

  log "Очікування готовності MinIO для створення бакета..."
  kubectl rollout status deployment/minio -n minio --timeout=90s || true

  # Автоматичне створення бакета velero за допомогою тимчасового mc пода
  kubectl run minio-mc-init --image=minio/mc --namespace=minio --restart=Never --rm -i -- \
    sh -c "mc alias set myminio http://minio-service.minio.svc.cluster.local:9000 ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD} && mc mb --ignore-existing myminio/velero" || true

  # 2. Створюємо секрет для підключення Velero до MinIO
  cat >/tmp/velero-creds <<EOF
[default]
aws_access_key_id=${MINIO_ROOT_USER}
aws_secret_access_key=${MINIO_ROOT_PASSWORD}
EOF

  # 3. Встановлюємо Velero (перенаправляємо на новий minio-service)
  helm upgrade --install velero vmware-tanzu/velero -n velero \
    --set snapshotsEnabled=false \
    --set configuration.backupStorageLocation[0].name=default \
    --set configuration.backupStorageLocation[0].provider=aws \
    --set configuration.backupStorageLocation[0].bucket=velero \
    --set configuration.backupStorageLocation[0].config.region=minio \
    --set configuration.backupStorageLocation[0].config.s3ForcePathStyle="true" \
    --set configuration.backupStorageLocation[0].config.s3Url=http://minio-service.minio.svc.cluster.local:9000 \
    --set credentials.secretContents.cloud="$(cat /tmp/velero-creds)" \
    --set initContainers[0].name=velero-plugin-for-aws \
    --set initContainers[0].image=velero/velero-plugin-for-aws:v1.9.0 \
    --set initContainers[0].volumeMounts[0].mountPath=/target \
    --set initContainers[0].volumeMounts[0].name=plugins
}

setup_longhorn() {
  log "Installing Longhorn..."
  helm repo add longhorn https://charts.longhorn.io
  helm repo update
  kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -
  helm upgrade --install longhorn longhorn/longhorn -n longhorn-system
}

# =========================================================
# 10. NAMESPACES & POD SECURITY
# =========================================================

log "Creating namespaces..."
for ns in monitoring ingress-nginx cert-manager argocd portainer registry tekton-pipelines minio velero; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

log "Applying Pod Security labels..."
kubectl label namespace monitoring pod-security.kubernetes.io/enforce=privileged --overwrite

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
# 12. INGRESS NGINX & METRICS SERVER
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

log "Installing metrics-server..."
helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system \
  --set args="{--kubelet-insecure-tls}"

# =========================================================
# 13. CERT MANAGER & CLOUDFLARE
# =========================================================

log "Installing cert-manager..."
helm upgrade --install cert-manager jetstack/cert-manager --namespace cert-manager --set installCRDs=true
kubectl wait --for=condition=Established crd/certificates.cert-manager.io --timeout=120s
kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=120s

kubectl create secret generic cloudflare-api-token-secret \
  -n cert-manager \
  --from-literal=api-token="${CF_API_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

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
# 14. MONITORING STACK (PROMETHEUS, GRAFANA, LOKI)
# =========================================================

log "Installing monitoring stack..."
# (Ваш блок для Prometheus/Grafana виглядає добре, залишаємо без змін)
cat >/tmp/prom-values.yaml <<EOF
grafana:
  enabled: true
  adminPassword: "${GRAFANA_ADMIN_PASSWORD}"
  persistence: { enabled: true, size: 5Gi }
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits: { cpu: 500m, memory: 768Mi }
prometheus:
  prometheusSpec:
    retention: ${PROM_RETENTION}
    scrapeInterval: 60s
    serviceMonitorSelectorNilUsesHelmValues: false
    serviceMonitorSelector: {}
    serviceMonitorNamespaceSelector: {}
    resources:
      requests: { cpu: 150m, memory: 400Mi }
      limits: { cpu: 500m, memory: 1Gi }
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources: { requests: { storage: 15Gi } }
alertmanager:
  enabled: true
  config:
    route:
      group_by: ['namespace', 'alertname']
      receiver: 'signal-adapter'
      routes:
        - receiver: 'blackhole'
          matchers: [ "alertname =~ \"InfoInhibitor|Watchdog\"" ]
    receivers:
      - name: 'blackhole'
      - name: 'signal-adapter'
        webhook_configs:
          - url: http://signal-adapter-service.monitoring.svc.cluster.local:8000/webhook
            send_resolved: true
            http_config: { authorization: { credentials: "${WEBHOOK_TOKEN}" } }
EOF

helm upgrade --install monitoring prometheus-community/kube-prometheus-stack --namespace monitoring -f /tmp/prom-values.yaml --create-namespace

log "Installing Loki & Promtail..."
cat >/tmp/loki-values.yaml <<EOF
deploymentMode: SingleBinary
loki:
  auth_enabled: false
  commonConfig: { replication_factor: 1 }
  storage: { type: filesystem }
  schemaConfig:
    configs:
      - from: "2024-01-01"
        object_store: filesystem
        store: tsdb
        schema: v13
        index: { prefix: index_, period: 24h }
  limits_config: { retention_period: ${LOKI_RETENTION} }

singleBinary:
  replicas: 1
  resources:
    requests: { cpu: 50m, memory: 128Mi }
    limits: { cpu: 300m, memory: 512Mi }
  persistence:
    enabled: true
    size: 10Gi
    storageClass: local-path

read: { replicas: 0 }
write: { replicas: 0 }
backend: { replicas: 0 }
EOF

helm upgrade --install loki grafana/loki --namespace monitoring -f /tmp/loki-values.yaml

log "Installing Promtail..."
helm upgrade --install promtail grafana/promtail --namespace monitoring \
  --set loki.serviceName=loki-gateway \
  --set config.clients[0].url=http://loki-gateway.monitoring.svc.cluster.local:80/loki/api/v1/push \
  --set resources.limits.memory=128Mi

# =========================================================
# 15. SIGNAL AUTHENTICATION & ADAPTER
# =========================================================

log "Initializing Signal authentication..."
SIGNAL_DIR="/var/lib/signal-cli"
mkdir -p "$SIGNAL_DIR" && chmod 777 "$SIGNAL_DIR" 

if ! grep -q "$SIGNAL_NUMBER" <(ls -1 "$SIGNAL_DIR/data" 2>/dev/null || true); then
    log "Signal не авторизовано. Запуск фонового Pod для генерації QR-посилання..."
    if ! command -v qrencode &> /dev/null; then apt-get update -qq && apt-get install -y qrencode -qq; fi
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
    hostPath: { path: "${SIGNAL_DIR}", type: DirectoryOrCreate }
EOF

    QR_LINK=""
    for i in {1..60}; do
        QR_LINK=$(kubectl logs signal-linker -n monitoring 2>/dev/null | grep -oE "sgnl://[^ ]+" | tail -n 1 || true)
        if [[ -n "$QR_LINK" ]]; then break; fi
        sleep 3
    done

    if [[ -z "$QR_LINK" ]]; then
        kubectl delete pod signal-linker -n monitoring --ignore-not-found 2>/dev/null || true
        error "Не вдалося отримати QR-посилання."
    fi

    echo -e "${YELLOW}================ SIGNAL QR AUTH =================${NC}"
    echo "$QR_LINK" | qrencode -t UTF8
    echo "Посилання: $QR_LINK"
    echo -e "${YELLOW}=================================================${NC}"

    SUCCESS=0
    for i in {1..24}; do
        POD_STATUS=$(kubectl get pod signal-linker -n monitoring -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [[ "$POD_STATUS" == "Succeeded" ]]; then SUCCESS=1; break; fi
        sleep 5
    done
    kubectl delete pod signal-linker -n monitoring --ignore-not-found 2>/dev/null || true
    if [ $SUCCESS -eq 1 ]; then log "Signal авторизовано ✔"; else error "Тайм-аут очікування."; fi
else
    log "Signal вже авторизовано."
fi

log "Deploying Signal REST API & Python Translator..."
cat >/tmp/signal_main.py <<'PY'
import json, os, urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

TOKEN = os.getenv("WEBHOOK_TOKEN")
SIGNAL_API_URL = os.getenv("SIGNAL_API_URL", "http://127.0.0.1:8080")
SIGNAL_NUMBER = os.getenv("SIGNAL_NUMBER")
SIGNAL_RECIPIENTS = [r.strip() for r in os.getenv("SIGNAL_RECIPIENTS", "").split(",") if r.strip()]

def send_to_signal(message):
    for recipient in SIGNAL_RECIPIENTS:
        payload = {"number": SIGNAL_NUMBER, "recipients": [recipient], "message": message}
        try:
            req = urllib.request.Request(f"{SIGNAL_API_URL}/v2/send", data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"}, method="POST")
            urllib.request.urlopen(req, timeout=10)
        except Exception as e: print(f"Error: {e}")

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/webhook" or self.headers.get("Authorization") != f"Bearer {TOKEN}":
            self.send_response(401)
            self.end_headers()
            return
        try:
            data = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))).decode())
            for alert in data.get("alerts", []):
                l = alert.get("labels", {})
                emoji = "🟢" if data.get("status") == "resolved" else ("🚨" if l.get("severity", "").upper() == "CRITICAL" else "⚠️")
                text = f"{emoji} {l.get('alertname', 'Alert')}\nSeverity: {l.get('severity', 'info')}\nNS: {l.get('namespace', 'default')}\nDesc: {alert.get('annotations', {}).get('description', '')}"
                send_to_signal(text)
            self.send_response(200)
        except: self.send_response(400)
        self.end_headers()
if __name__ == "__main__": HTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
PY

kubectl create configmap signal-adapter-code -n monitoring --from-file=main.py=/tmp/signal_main.py --dry-run=client -o yaml | kubectl apply -f -

cat >/tmp/signal-adapter.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: { name: signal-adapter, namespace: monitoring }
spec:
  replicas: 1
  selector: { matchLabels: { app: signal-adapter } }
  template:
    metadata: { labels: { app: signal-adapter } }
    spec:
      containers:
        - name: python-adapter
          image: python:3.11-slim
          command: ["python", "/app/main.py"]
          env:
            - { name: SIGNAL_NUMBER, value: "${SIGNAL_NUMBER}" }
            - { name: SIGNAL_RECIPIENTS, value: "${SIGNAL_RECIPIENTS}" }
            - { name: WEBHOOK_TOKEN, value: "${WEBHOOK_TOKEN}" }
          volumeMounts: [{ name: code-volume, mountPath: /app }]
        - name: signal-rest-api
          image: bbernhard/signal-cli-rest-api:latest
          env:
            - { name: MODE, value: "native" }
            - { name: SIGNAL_CLI_OPTS, value: "--config /home/.local/share/signal-cli" }
          volumeMounts: [{ name: signal-data, mountPath: /home/.local/share/signal-cli }]
      volumes:
        - { name: code-volume, configMap: { name: signal-adapter-code } }
        - { name: signal-data, hostPath: { path: "$SIGNAL_DIR", type: DirectoryOrCreate } }
---
apiVersion: v1
kind: Service
metadata: { name: signal-adapter-service, namespace: monitoring }
spec:
  ports: [{ port: 8000, targetPort: 8000 }]
  selector: { app: signal-adapter }
EOF
kubectl apply -f /tmp/signal-adapter.yaml

# =========================================================
# 16. PORTAINER (SERVER OR AGENT)
# =========================================================

if [ "$PORTAINER_CHOICE" == "2" ]; then
  log "Installing Portainer Server..."
  helm upgrade --install portainer portainer/portainer --namespace portainer --set tls.force=false --set resources.requests.cpu=50m --set resources.requests.memory=128Mi
else
  log "Installing Portainer Agent Only..."
  kubectl apply -n portainer -f https://downloads.portainer.io/ce2-21/portainer-agent-k8s-nodeport.yaml
fi

# =========================================================
# 17. ARGOCD
# =========================================================

log "Installing ArgoCD..."
helm upgrade --install argocd argo/argo-cd --namespace argocd --set server.resources.requests.cpu=50m --set server.resources.requests.memory=128Mi

# =========================================================
# 18. LOCAL REGISTRY & TEKTON CI (WITH RACE CONDITION FIXES)
# =========================================================

log "Deploying Local Image Registry..."
cat >/tmp/local-registry.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: { name: registry, namespace: registry }
spec:
  replicas: 1
  selector: { matchLabels: { app: registry } }
  template:
    metadata: { labels: { app: registry } }
    spec:
      containers:
        - name: registry
          image: registry:2
          ports: [{ containerPort: 5000 }]
          env: [{ name: REGISTRY_STORAGE_DELETE_ENABLED, value: "true" }]
          volumeMounts: [{ name: registry-data, mountPath: /var/lib/registry }]
      volumes:
        - name: registry-data
          hostPath: { path: /var/lib/registry-data, type: DirectoryOrCreate }
---
apiVersion: v1
kind: Service
metadata: { name: registry, namespace: registry }
spec:
  selector: { app: registry }
  ports: [{ port: 5000, targetPort: 5000 }]
EOF
kubectl apply -f /tmp/local-registry.yaml

log "Installing Tekton Components..."
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml
kubectl apply -f https://storage.googleapis.com/tekton-releases/dashboard/latest/release.yaml

# === КРИТИЧНИЙ БЛОК: ОЧІКУВАННЯ ВЕБХУКІВ ===
log "Waiting for Tekton webhooks to initialize (preventing race conditions)..."
for deploy in tekton-pipelines-webhook tekton-triggers-webhook; do
  kubectl rollout status deployment/"$deploy" -n tekton-pipelines --timeout=180s || true
done

log "Webhooks ready. Installing Tekton Tasks with retry mechanism..."
# === КРИТИЧНИЙ БЛОК: RETRY ЦИКЛ ===
for i in {1..10}; do
  if kubectl apply -f https://raw.githubusercontent.com/tektoncd/catalog/main/task/git-clone/0.9/git-clone.yaml -n tekton-pipelines 2>/dev/null; then
    log "git-clone task installed successfully."
    break
  fi
  warn "Webhook endpoint not fully populated yet. Retrying in 5 seconds... ($i/10)"
  sleep 5
done

for i in {1..10}; do
  if kubectl apply -f https://raw.githubusercontent.com/tektoncd/catalog/main/task/kaniko/0.6/kaniko.yaml -n tekton-pipelines 2>/dev/null; then
    log "kaniko task installed successfully."
    break
  fi
  sleep 5
done

# =========================================================
# 19. TEKTON WEBHOOK INTEGRATION
# =========================================================

log "Configuring Tekton CI/CD Bridge..."
kubectl create serviceaccount tekton-ci-sa -n tekton-pipelines --dry-run=client -o yaml | kubectl apply -f -
kubectl create clusterrolebinding tekton-ci-admin --clusterrole=cluster-admin --serviceaccount=tekton-pipelines:tekton-ci-sa --dry-run=client -o yaml | kubectl apply -f -

WEBHOOK_SECRET="gena-$(openssl rand -hex 16)"
kubectl create secret generic webhook-secret -n tekton-pipelines --from-literal=secret="${WEBHOOK_SECRET}" --dry-run=client -o yaml | kubectl apply -f -

cat >/tmp/tekton-hooks.yaml <<EOF
apiVersion: triggers.tekton.dev/v1beta1
kind: TriggerBinding
metadata:
  name: universal-binding
  namespace: tekton-pipelines
spec:
  params:
    - name: git-revision
      value: "\$(body.head_commit.id != null ? body.head_commit.id : body.checkout_sha)"
    - name: git-url
      value: "\$(body.repository.url != null ? body.repository.url : body.repository.git_http_url)"
---
apiVersion: triggers.tekton.dev/v1beta1
kind: TriggerTemplate
metadata:
  name: universal-template
  namespace: tekton-pipelines
spec:
  params:
    - name: git-revision
    - name: git-url
  resourcetemplates:
    - apiVersion: tekton.dev/v1beta1
      kind: PipelineRun
      metadata:
        generateName: build-run-
      spec:
        serviceAccountName: tekton-ci-sa
        pipelineRef:
          name: build-my-app-pipeline
        workspaces:
          - name: shared-data
            volumeClaimTemplate:
              spec:
                accessModes: ["ReadWriteOnce"]
                resources:
                  requests:
                    storage: 1Gi
        params:
          - name: repo-url
            value: "\$(tt.params.git-url)"
          - name: revision
            value: "\$(tt.params.git-revision)"
---
apiVersion: triggers.tekton.dev/v1beta1
kind: EventListener
metadata:
  name: webhook-listener
  namespace: tekton-pipelines
spec:
  serviceAccountName: tekton-ci-sa
  triggers:
    - bindings:
        - ref: universal-binding
      template:
        ref: universal-template
      interceptors:
        - ref:
            name: cel
          params:
            - name: filter
              value: "(header.has('x-github-event')) || (header.has('x-gitlab-token') && header.x_gitlab_token == '${WEBHOOK_SECRET}')"
EOF
kubectl apply -f /tmp/tekton-hooks.yaml

cat >/tmp/tekton-pipeline.yaml <<EOF
apiVersion: tekton.dev/v1beta1
kind: Pipeline
metadata: { name: build-my-app-pipeline, namespace: tekton-pipelines }
spec:
  params: [{ name: repo-url }, { name: revision }]
  workspaces: [{ name: shared-data }]
  tasks:
    - name: fetch-source
      taskRef: { name: git-clone }
      workspaces: [{ name: output, workspace: shared-data }]
      params: [{ name: url, value: "\$(params.repo-url)" }, { name: revision, value: "\$(params.revision)" }]
    - name: build-and-push
      runAfter: [fetch-source]
      taskRef: { name: kaniko }
      workspaces: [{ name: source, workspace: shared-data }]
      params:
        - { name: IMAGE, value: "registry.registry.svc.cluster.local:5000/apps/\$(context.pipelineRun.name):latest" }
        - { name: DOCKERFILE, value: "./Dockerfile" }
EOF
kubectl apply -f /tmp/tekton-pipeline.yaml

# =========================================================
# 20. INGRESS
# =========================================================

log "Configuring ingress..."
cat >/tmp/ingresses.yaml <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana-ingress
  namespace: monitoring
  annotations: { cert-manager.io/cluster-issuer: ${LE_ISSUER_NAME} }
spec:
  ingressClassName: nginx
  tls: [{ hosts: [${GRAFANA_HOST}], secretName: grafana-tls }]
  rules:
    - host: ${GRAFANA_HOST}
      http:
        paths: [{ path: /, pathType: Prefix, backend: { service: { name: monitoring-grafana, port: { number: 80 } } } }]
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
  tls: [{ hosts: [${ARGOCD_HOST}], secretName: argocd-tls }]
  rules:
    - host: ${ARGOCD_HOST}
      http:
        paths: [{ path: /, pathType: Prefix, backend: { service: { name: argocd-server, port: { number: 443 } } } }]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: tekton-dashboard-ingress
  namespace: tekton-pipelines
  annotations: { cert-manager.io/cluster-issuer: ${LE_ISSUER_NAME} }
spec:
  ingressClassName: nginx
  tls: [{ hosts: [${TEKTON_HOST}], secretName: tekton-tls }]
  rules:
    - host: ${TEKTON_HOST}
      http:
        paths: [{ path: /, pathType: Prefix, backend: { service: { name: tekton-dashboard, port: { number: 9097 } } } }]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: tekton-webhook-ingress
  namespace: tekton-pipelines
  annotations:
    cert-manager.io/cluster-issuer: ${LE_ISSUER_NAME}
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  tls: [{ hosts: [${TEKTON_HOST}], secretName: tekton-tls }]
  rules:
    - host: ${TEKTON_HOST}
      http:
        paths: [{ path: /webhook, pathType: Prefix, backend: { service: { name: el-webhook-listener, port: { number: 8080 } } } }]
EOF

if [ "$PORTAINER_CHOICE" == "2" ]; then
cat >>/tmp/ingresses.yaml <<EOF
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: portainer-ingress
  namespace: portainer
  annotations: { cert-manager.io/cluster-issuer: ${LE_ISSUER_NAME} }
spec:
  ingressClassName: nginx
  tls: [{ hosts: [${PORTAINER_HOST}], secretName: portainer-tls }]
  rules:
    - host: ${PORTAINER_HOST}
      http:
        paths: [{ path: /, pathType: Prefix, backend: { service: { name: portainer, port: { number: 9000 } } } }]
EOF
fi

if [[ "$BACKUP_CHOICE" == "3" || "$BACKUP_CHOICE" == "2" ]]; then
cat >>/tmp/ingresses.yaml <<EOF
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: minio-ingress
  namespace: minio
  annotations: { cert-manager.io/cluster-issuer: ${LE_ISSUER_NAME} }
spec:
  ingressClassName: nginx
  tls: [{ hosts: [${MINIO_HOST}], secretName: minio-tls }]
  rules:
    - host: ${MINIO_HOST}
      http:
        paths: [{ path: /, pathType: Prefix, backend: { service: { name: minio-service, port: { number: 9090 } } } }]
EOF
fi

kubectl apply -f /tmp/ingresses.yaml

# =========================================================
# 21. FINAL CONFIGURATION & OUTPUT
# =========================================================

case "$BACKUP_CHOICE" in
  1) setup_pbs_client ;;
  2) setup_velero_standard ;;
  3) setup_velero_minio ;;
  4) setup_longhorn ;;
  *) log "Backup залишлено на рівні PVE." ;;
esac

log "Очікування генерації секрету адміна ArgoCD..."
for i in {1..60}; do
  if kubectl get secret argocd-initial-admin-secret -n argocd >/dev/null 2>&1; then break; fi
  sleep 5
done
ARGOCD_PWD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d 2>/dev/null || echo "Changed/Not Found")

echo
echo -e "${GREEN}=================================================${NC}"
echo -e "${GREEN}   G.E.N.A. УСПІШНО РОЗГОРНУТА!                  ${NC}"
echo -e "${GREEN}=================================================${NC}"
echo
echo
echo -e "${YELLOW}================ CONTROL PANELS =================${NC}"
echo -e "${BLUE}Cockpit:${NC}        https://${NODE_IP}:9090"
echo -e "${BLUE}Grafana:${NC}        https://${GRAFANA_HOST} (User: admin, Pass: ${GRAFANA_ADMIN_PASSWORD})"
echo -e "${BLUE}ArgoCD:${NC}         https://${ARGOCD_HOST} (User: admin, Pass: ${ARGOCD_PWD})"
echo -e "${BLUE}Tekton CI:${NC}      https://${TEKTON_HOST}"
echo -e "${BLUE}Local Registry:${NC} registry.registry.svc.cluster.local:5000"

if [ "$PORTAINER_CHOICE" == "2" ]; then
  echo -e "${BLUE}Portainer:${NC}      https://${PORTAINER_HOST}"
fi

if [[ "$BACKUP_CHOICE" == "2" || "$BACKUP_CHOICE" == "3" ]]; then
  echo -e "${BLUE}MinIO Console:${NC}  https://${MINIO_HOST} (User: ${MINIO_ROOT_USER}, Pass: ${MINIO_ROOT_PASSWORD})"
fi

echo -e "${YELLOW}================ TEKTON CI/CD ===================${NC}"
echo -e "${BLUE}Webhook URL:${NC}    https://${TEKTON_HOST}/webhook"
echo -e "${BLUE}Webhook Secret:${NC} ${WEBHOOK_SECRET}"
echo -e "${YELLOW}=================================================${NC}"
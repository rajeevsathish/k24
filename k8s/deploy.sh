#!/bin/bash
# deploy.sh — Deploy a 3-node Keycloak 24.0.4 cluster on Minikube
# Run from the keycloak-24.0.4/ directory

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/resources" && pwd)"

echo "=== Step 1: Start Minikube (if not running) ==="
if ! minikube status &>/dev/null; then
  minikube start --cpus=4 --memory=6144 --driver=docker
fi

echo "=== Step 2: Enable Ingress addon ==="
minikube addons enable ingress

echo "=== Step 3: Copy themes, providers, and realm into Minikube VM ==="
# Minikube mounts /data automatically when using the docker driver
minikube ssh -- "sudo rm -rf /data/keycloak && sudo mkdir -p /data/keycloak/themes /data/keycloak/providers /data/keycloak/realm"

# Copy sunbird theme
minikube cp "$SCRIPT_DIR/themes/sunbird" /data/keycloak/themes/sunbird

# Copy provider JAR
minikube cp "$SCRIPT_DIR/providers/keycloak-email-phone-autthenticator-1.0-SNAPSHOT.jar" \
  /data/keycloak/providers/keycloak-email-phone-autthenticator-1.0-SNAPSHOT.jar

# Copy realm import
minikube cp "$SCRIPT_DIR/realm/sunbird-realm.json" /data/keycloak/realm/sunbird-realm.json

echo "=== Step 4: Apply Kubernetes manifests ==="
kubectl apply -f "$SCRIPT_DIR/k8s/00-namespace.yaml"
#kubectl apply -f "$SCRIPT_DIR/k8s/01-postgres.yaml"

echo "Waiting for PostgreSQL to be ready..."
kubectl -n keycloak rollout status deployment/postgres --timeout=120s

kubectl apply -f "$SCRIPT_DIR/k8s/02-keycloak-config.yaml"
kubectl apply -f "$SCRIPT_DIR/k8s/03-keycloak-statefulset.yaml"
kubectl apply -f "$SCRIPT_DIR/k8s/04-ingress.yaml"

echo "Waiting for Keycloak pods to be ready..."
kubectl -n keycloak rollout status statefulset/keycloak --timeout=300s

echo ""
echo "=== Deployment complete! ==="
echo ""
echo "Add this to /etc/hosts:"
MINIKUBE_IP=$(minikube ip)
echo "  $MINIKUBE_IP  keycloak.local"
echo ""
echo "Then open: http://keycloak.local"
echo "Admin console: http://keycloak.local/admin"
echo "  Username: admin"
echo "  Password: sunbird"
echo ""
echo "Verify cluster members:"
echo "  kubectl -n keycloak logs keycloak-0 | grep -i 'members'"

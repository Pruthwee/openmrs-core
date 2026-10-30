#!/bin/bash
# Deploys the pushed OpenMRS image to AWS EKS with kubectl.
# Run it from the repository root: ./scripts/deploy-image.sh
set -e
set -o pipefail

APP_NAME="openmrs-cont"
NAMESPACE="openmrs-cont"
SECRET_NAME="${APP_NAME}-secrets"

echo "=== Deploy ${APP_NAME} to AWS EKS ==="

for tool in aws kubectl sed; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: $tool is not installed or not in PATH"
    exit 1
  fi
done

for manifest in namespace deployment service ingress; do
  if [ ! -f "kubernetes/${manifest}.yaml" ]; then
    echo "ERROR: kubernetes/${manifest}.yaml not found, run this script from the repository root"
    exit 1
  fi
done

# ---- Cluster details ----
read -r -p "Enter the AWS region (for example us-east-1): " AWS_REGION
read -r -p "Enter the EKS cluster name: " CLUSTER_NAME
read -r -p "Enter the image URI (registry/repository:tag, as printed by build-push.sh): " IMAGE_URI
if [ -z "$AWS_REGION" ] || [ -z "$CLUSTER_NAME" ] || [ -z "$IMAGE_URI" ]; then
  echo "ERROR: the AWS region, the cluster name and the image URI are required"
  exit 1
fi

# ---- Application configuration (a "{{VARIABLE}}" placeholder in kubernetes/deployment.yaml each) ----
ask_value() {
  # $1 = variable name, $2 = value used when Enter is pressed
  local value
  read -r -p "Enter value for $1 (or press Enter to skip) [$2]: " value
  printf -v "$1" '%s' "${value:-$2}"
}

ask_value OMRS_DB "mariadb"
ask_value OMRS_DB_HOSTNAME "localhost"
ask_value OMRS_DB_PORT "3306"
ask_value OMRS_DB_NAME "openmrs"
ask_value OMRS_DB_USERNAME "openmrs"
ask_value OMRS_ADMIN_PASSWORD_LOCKED "true"
ask_value OMRS_CREATE_TABLES "true"
ask_value OMRS_AUTO_UPDATE_DATABASE "true"
ask_value OMRS_SEARCH "lucene"
ask_value OMRS_SEARCH_ES_URIS "http://elasticsearch:9200"

# ---- Credentials (not echoed) ----
read -r -s -p "Enter value for OMRS_DB_PASSWORD: " OMRS_DB_PASSWORD
echo ""
read -r -s -p "Enter value for OMRS_ADMIN_USER_PASSWORD: " OMRS_ADMIN_USER_PASSWORD
echo ""
if [ -z "$OMRS_DB_PASSWORD" ] || [ -z "$OMRS_ADMIN_USER_PASSWORD" ]; then
  echo "ERROR: OMRS_DB_PASSWORD and OMRS_ADMIN_USER_PASSWORD are required"
  exit 1
fi

# ---- kubectl for the EKS cluster ----
echo "Configuring kubectl for cluster ${CLUSTER_NAME} in ${AWS_REGION} ..."
aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME || { echo "ERROR: aws eks update-kubeconfig failed, check the AWS credentials, the region and the cluster name"; exit 1; }
kubectl cluster-info || exit 1

# The manifests are edited in place; keep the templates and put them back when the script ends
BACKUP_DIR=$(mktemp -d)
cp kubernetes/deployment.yaml "$BACKUP_DIR/deployment.yaml"
restore_templates() {
  cp "$BACKUP_DIR/deployment.yaml" kubernetes/deployment.yaml
  rm -f kubernetes/deployment.yaml.bak
  rm -rf "$BACKUP_DIR"
}
trap restore_templates EXIT

rollback_help() {
  echo ""
  echo "The deployment failed. To roll back to the previous revision:"
  echo "  kubectl rollout undo deployment/${APP_NAME} -n ${NAMESPACE}"
  echo "To inspect it:"
  echo "  kubectl describe deployment/${APP_NAME} -n ${NAMESPACE}"
  echo "  kubectl logs deployment/${APP_NAME} -n ${NAMESPACE}"
  echo "  kubectl get events -n ${NAMESPACE} --sort-by=.lastTimestamp"
}

# ---- Namespace and Secret ----
echo "Applying kubernetes/namespace.yaml ..."
kubectl apply -f kubernetes/namespace.yaml || { echo "ERROR: could not apply the namespace"; exit 1; }

echo "Creating the Secret ${SECRET_NAME} ..."
kubectl create secret generic ${SECRET_NAME} -n ${NAMESPACE} \
  --from-literal=OMRS_DB_PASSWORD="$OMRS_DB_PASSWORD" \
  --from-literal=OMRS_ADMIN_USER_PASSWORD="$OMRS_ADMIN_USER_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f - || { echo "ERROR: could not create the Secret"; exit 1; }

# ---- Placeholders ----
escape_sed() {
  printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

replace_placeholder() {
  # $1 = placeholder name, $2 = value
  sed -i.bak "s|{{$1}}|$(escape_sed "$2")|g" kubernetes/deployment.yaml
  rm -f kubernetes/deployment.yaml.bak
}

replace_placeholder IMAGE_URI "$IMAGE_URI"
replace_placeholder NAMESPACE "$NAMESPACE"
replace_placeholder OMRS_DB "$OMRS_DB"
replace_placeholder OMRS_DB_HOSTNAME "$OMRS_DB_HOSTNAME"
replace_placeholder OMRS_DB_PORT "$OMRS_DB_PORT"
replace_placeholder OMRS_DB_NAME "$OMRS_DB_NAME"
replace_placeholder OMRS_DB_USERNAME "$OMRS_DB_USERNAME"
replace_placeholder OMRS_ADMIN_PASSWORD_LOCKED "$OMRS_ADMIN_PASSWORD_LOCKED"
replace_placeholder OMRS_CREATE_TABLES "$OMRS_CREATE_TABLES"
replace_placeholder OMRS_AUTO_UPDATE_DATABASE "$OMRS_AUTO_UPDATE_DATABASE"
replace_placeholder OMRS_SEARCH "$OMRS_SEARCH"
replace_placeholder OMRS_SEARCH_ES_URIS "$OMRS_SEARCH_ES_URIS"

if grep -q '{{' kubernetes/deployment.yaml; then
  echo "ERROR: placeholders are left in kubernetes/deployment.yaml"
  grep -n '{{' kubernetes/deployment.yaml
  exit 1
fi

# ---- Deploy ----
echo "Applying kubernetes/deployment.yaml ..."
kubectl apply -f kubernetes/deployment.yaml || { echo "ERROR: could not apply the deployment"; rollback_help; exit 1; }
echo "Applying kubernetes/service.yaml ..."
kubectl apply -f kubernetes/service.yaml || { echo "ERROR: could not apply the service"; rollback_help; exit 1; }
echo "Applying kubernetes/ingress.yaml ..."
kubectl apply -f kubernetes/ingress.yaml || { echo "ERROR: could not apply the ingress (is the AWS Load Balancer Controller installed?)"; rollback_help; exit 1; }

echo "Waiting for the rollout (OpenMRS needs several minutes on first start) ..."
if ! kubectl rollout status deployment/${APP_NAME} -n ${NAMESPACE} --timeout=900s; then
  echo "ERROR: the rollout did not complete"
  rollback_help
  exit 1
fi

echo ""
kubectl get pods,svc,ingress -n ${NAMESPACE}

INGRESS_HOST=$(kubectl get ingress ${APP_NAME}-ingress -n ${NAMESPACE} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
echo ""
if [ -n "$INGRESS_HOST" ]; then
  echo "Application URL: http://${INGRESS_HOST}/openmrs (send the Host header ${APP_NAME}.example.com, or point that DNS name at the load balancer)"
else
  echo "The load balancer address is not assigned yet. Check later with:"
  echo "  kubectl get ingress ${APP_NAME}-ingress -n ${NAMESPACE}"
fi
echo "Deployment finished."

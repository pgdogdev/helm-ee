# Prerequisites Installation

You have two options for installing nginx-ingress and cert-manager:

**Option A: Automatic installation (simpler)**
Enable them in `values.yaml` and they'll be installed automatically with the chart:
```yaml
ingress-nginx:
  enabled: true
cert-manager:
  enabled: true
```

Then run:
```bash
helm dependency update enterprise/infra/helm
helm install pgdog-control enterprise/infra/helm
```

**Option B: Manual installation (recommended for production)**
Install them separately as cluster-wide infrastructure (instructions below). This is recommended when:
- Multiple applications share the same ingress controller and cert-manager
- You want independent lifecycle management
- You're deploying to a shared cluster

---

## Manual Installation Steps

## 1. Install nginx-ingress-controller

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=LoadBalancer
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-scheme"=internet-facing
```

Wait for the LoadBalancer to get an external IP:
```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller --watch
```

## 2. Install cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --set global.leaderElection.namespace=cert-manager
```

Verify cert-manager is running:
```bash
kubectl get pods -n cert-manager
```

**Troubleshoot webhook errors**: If you get webhook certificate errors, restart cert-manager:
```bash
kubectl delete pod -n cert-manager -l app.kubernetes.io/instance=cert-manager
kubectl wait --for=condition=ready pod -n cert-manager -l app.kubernetes.io/instance=cert-manager --timeout=120s
```

## 3. Create LetsEncrypt ClusterIssuer

Create a file named `letsencrypt-prod.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com  # CHANGE THIS
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
```

Apply it:
```bash
kubectl apply -f letsencrypt-prod.yaml
```

## 4. Update DNS

Point your domain `internal.gcp.pgdog.dev` to the LoadBalancer IP from step 1:

```bash
# Get the LoadBalancer IP
kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

Create an A record in your DNS provider pointing to this IP.

## 5. Deploy the control app

```bash
helm install pgdog-control enterprise/infra/helm
```

## Verify deployment

```bash
# Check pods
kubectl get pods -l app=pgdog-control

# Check ingress
kubectl get ingress pgdog-control

# Check certificate
kubectl get certificate pgdog-control-tls

# Check cert-manager logs if certificate isn't ready
kubectl logs -n cert-manager -l app=cert-manager -f
```

## Secret generation

```
python -c "import secrets; print(secrets.token_urlsafe(64))"
```

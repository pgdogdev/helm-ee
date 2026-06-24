# PgDog EE Helm Chart

Production-ready [Helm](https://helm.sh) chart for the PgDog Enterprise
[Control Plane](https://docs.pgdog.dev/enterprise_edition/control_plane/).

## Installation

### Guided installation

This chart has a few dependencies, like having a valid `Ingress` controller and an IAM role
to allow the web dashboard read-only access to RDS and CloudWatch.

To quickly check that your EKS cluster has everything, you can run this Bash script:

```sh
curl -fsSL https://raw.githubusercontent.com/pgdogdev/helm-ee/main/install.sh | bash
```

It's strictly read-only and will print out warnings or errors. It can also help generate a valid
IAM role with a Trust Policy.

### Manual install

Install the chart with Helm (read below for configuration options):

```sh
helm repo add pgdogdev-ee https://helm-ee.pgdog.dev
helm install control pgdogdev-ee/pgdog-control
```

The three somewhat complex steps are:

1. Configuring AWS RDS/CloudWatch permissions (IAM)
2. Setting up an Ingress with TLS termination (nginx, ALB and Gateway API supported)
3. Configuring OAuth for the control plane dashboard (GitHub and Google auth supported)

## Chart summary

This chart installs two deployments: PgDog control plane and Redis.

The PgDog deployment contains the following components:

| Components | Description |
|-|-|
| Deployment | PgDog control plane deployment, with one replica. |
| Service | Service pointing to the deployment. Selector labels are configured automatically. |
| Ingress / HTTPRoute | Four (4) routing modes are supported: Nginx, AWS ALB, Gateway API, and Default. See [ingress](#ingress) for more details. |
| ConfigMap | Configuration for the control plane. |
| Secret | Secret that stores the key used to encrypt authentication cookies. |
| Service account, Cluster role, Cluster role bindings | Service account with RBAC to access select Kube APIs. See [RBAC](#rbac) for more details. |

In addition to installing the PgDog control plane, this chart will deploy a Redis deployment (with one replica). The control plane uses Redis for storing
metrics. The Redis deployment has the following components:

| Components | Description |
|-|-|
| Deployment | Redis deployment with one replica. |
| Service | Redis service pointing to the deployment, with selector labels configured automatically. |

### Ingress

The PgDog control plane has a web dashboard. It can be accessed through the Ingress or HTTPRoute the chart creates. The chart supports 4 presets (called modes):

- Nginx
- AWS ALB
- Gateway API
- Default

Nginx and AWS ALB are Ingress-based presets with set annotations that should work for most deployments. Gateway API renders an HTTPRoute instead of an Ingress; use it when traffic enters through a Gateway controller. The Default mode allows the user to configure all Ingress options (class, annotations, etc.).

The mode is selected by `ingress.mode`. In `nginx`, `aws`, and `default` modes, the chart renders exactly one Ingress, whose rule always routes `/` to the control Service on port 80. In `gateway` mode, the chart renders an HTTPRoute instead. Only one of these resources is created per install.

All three modes share the options below:

| Option | Description |
|-|-|
| `ingress.enabled` | Enable/disable the Ingress (bool, default `true`). |
| `ingress.mode` | One of `nginx`, `aws`, `gateway`, or `default`. Defaults to `nginx`. |
| `ingress.host` | External hostname, e.g. pgdog.acme.com. Required for Nginx and AWS ALB; optional for Default. |
| `ingress.labels` | Extra `metadata.labels` merged on top of the chart's standard labels (map, default `{}`). |

#### Nginx

The Nginx preset targets [ingress-nginx](https://kubernetes.github.io/ingress-nginx/) with [cert-manager](https://cert-manager.io/) handling certificate issuance. The chart hardcodes `ingressClassName: nginx`, emits the cert-manager and ssl-redirect annotations, and renders a `tls` block that references `<release>-control-tls`. The cert-manager fills that Secret in response to the cluster issuer.

```yaml
ingress:
  enabled: true
  mode: nginx
  host: pgdog.acme.com
  nginx:
    tls:
      enabled: true
    clusterIssuer: letsencrypt-prod
    sslRedirect: "true"
```

| Option | Description |
|-|-|
| `ingress.nginx.tls.enabled` | When `true`, emits the cert-manager and ssl-redirect annotations and a `tls` block referencing `<release>-control-tls` (bool, default `true`). |
| `ingress.nginx.clusterIssuer` | Value of the `cert-manager.io/cluster-issuer` annotation (string, default `letsencrypt-prod`). |
| `ingress.nginx.sslRedirect` | Value of the `nginx.ingress.kubernetes.io/ssl-redirect` annotation. Quoted because nginx expects a string (string, default `"true"`). |

##### Finding an existing ClusterIssuer

If cert-manager is already installed, list the available issuers:

```sh
kubectl get clusterissuers
```

The output looks like:

```
NAME                  READY   AGE
letsencrypt-prod      True    42d
letsencrypt-staging   True    42d
```

Use the `NAME` column verbatim as `ingress.nginx.clusterIssuer`. `ClusterIssuer` is cluster-scoped, so you don't need `-n`. The issuer doesn't have to live in the release namespace.

Check that `READY` is `True`. If it isn't, run `kubectl describe clusterissuer <name>` and fix the issuer first. Otherwise the cert request will stay in `Pending` state.

If the command returns `error: the server doesn't have a resource type "clusterissuers"`, cert-manager isn't installed. See below.

##### Installing `ingress-nginx` and `cert-manager`

On a cluster with neither component, install both before installing this chart. Order matters. Install ingress-nginx first. Then cert-manager. Then create a ClusterIssuer.

**1. ingress-nginx**

```sh
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace
```

Wait for the controller's Service to get an external address. On most managed clusters that's a `LoadBalancer`. You'll need its hostname or IP for DNS:

```sh
kubectl -n ingress-nginx get svc ingress-nginx-controller -w
```

Point `control.acme.com` (or whatever `ingress.host` you'll use) at that address before continuing. Let's Encrypt's HTTP-01 challenge fails if the hostname doesn't resolve to the controller.

**2. cert-manager**

```sh
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true
```

**3. A ClusterIssuer**

cert-manager doesn't ship issuers. You create them. Here's a minimal Let's Encrypt production issuer that solves HTTP-01 through ingress-nginx:

```yaml
# letsencrypt-prod.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: you@acme.com
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
```

```sh
kubectl apply -f letsencrypt-prod.yaml
kubectl get clusterissuer letsencrypt-prod -w   # wait for READY=True
```

For first-time setup, point `server` at `https://acme-staging-v02.api.letsencrypt.org/directory` and create a separate `letsencrypt-staging` issuer. Staging has much higher rate limits. You can iterate on the install without burning prod issuance quota. Once it works, re-issue against the prod issuer.

Once the issuer is `READY=True`, set `ingress.nginx.clusterIssuer: letsencrypt-prod` in `values.yaml` and install the chart.

#### AWS ALB

The AWS ALB preset targets the [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/). The chart hardcodes `ingressClassName: alb` and `alb.ingress.kubernetes.io/target-type: ip`, and lets ACM terminate TLS at the load balancer. Supply an ACM cert ARN to get the HTTPS listener; leave it empty for HTTP-only.

```yaml
ingress:
  enabled: true
  mode: aws
  host: control.example.com
  aws:
    scheme: internet-facing
    subnets: subnet-aaa,subnet-bbb
    certificateArn: arn:aws:acm:us-east-1:111111111111:certificate/abc-123
    sslRedirect: true
```

| Option | Description |
|-|-|
| `ingress.aws.scheme` | `alb.ingress.kubernetes.io/scheme`. Either `internet-facing` or `internal` (string, default `internet-facing`). |
| `ingress.aws.subnets` | Optional comma-separated subnet IDs rendered as `alb.ingress.kubernetes.io/subnets`. Empty = controller auto-discovers subnets from AWS tags (string, default `""`). |
| `ingress.aws.certificateArn` | ACM cert ARN attached to the HTTPS listener. Empty = HTTP-only ALB, no 443 listener (string, default `""`). |
| `ingress.aws.sslRedirect` | When `true` and `certificateArn` is set, the ALB redirects HTTP:80 → HTTPS:443. Ignored when `certificateArn` is empty (bool, default `true`). |

#### Gateway API

The Gateway API mode is selected with `ingress.mode: gateway`. Instead of an Ingress, the chart renders an [HTTPRoute](https://gateway-api.sigs.k8s.io/api-types/httproute/) that attaches to an existing Gateway resource. Use this when your cluster routes traffic through a Gateway controller (Traefik, Envoy Gateway, AWS ALB via `gateway.k8s.aws`, etc.) and TLS is terminated at the Gateway or its backing load balancer.

```yaml
ingress:
  enabled: true
  mode: gateway
  host: control.example.com
  gateway:
    name: traefik-gw
    namespace: traefik
    sectionName: web
```

| Option | Description |
|-|-|
| `ingress.gateway.name` | Name of the Gateway resource the HTTPRoute attaches to (string, required). |
| `ingress.gateway.namespace` | Namespace of the Gateway resource (string, required). |
| `ingress.gateway.sectionName` | Selects a specific listener on the Gateway. Leave empty to attach to all listeners that match the hostname (string, optional). |

The chart does not create or manage the Gateway itself; that's expected to exist already. The HTTPRoute routes all paths (`/`) to the control Service on port 80, scoped to the hostname in `ingress.host`. TLS, certificates, and load balancer configuration are handled by the Gateway and its associated resources.

### Default

The Default mode is selected with `ingress.mode: default`. The chart adds nothing on top: no annotations, no `ingressClassName`, no `tls` block. You can route through any controller (Traefik, HAProxy, Contour, GKE, etc.) by supplying the keys it expects, for example:

```yaml
ingress:
  enabled: true
  mode: default
  host: control.example.com
  ingressClassName: traefik
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    cert-manager.io/cluster-issuer: letsencrypt-prod
  tls:
    - hosts: [control.example.com]
      secretName: control-tls
```

| Option | Description |
|-|-|
| `ingress.ingressClassName` | Rendered as `spec.ingressClassName` when non-empty (string, default `""`). |
| `ingress.annotations` | Rendered verbatim as `metadata.annotations` (map, default `{}`). |
| `ingress.tls` | Rendered verbatim under `spec.tls`. Supply the full `[{hosts, secretName}]` list (list, default `[]`). |

### DNS

If you need TLS, you will also need to setup DNS. In AWS, you can create a Route53 CNAME record pointing to the ALB and issue a cert for it in ACM. If using the Nginx controller, `cert-manager` will issue the certificate, but you still need to create a DNS record manually.

## RBAC

The control plane talks to the Kubernetes API in two distinct ways: it **reads** workloads from every namespace so the dashboard can render them, and it **writes** to a short list of namespaces where you actually want it to manage PgDog deployments.

When `control.rbac.create` is `true` (default), the chart renders:

- A `ServiceAccount` for the control pod. If `control.aws.roleArn` is set, the ServiceAccount also carries the `eks.amazonaws.com/role-arn` annotation, which is what EKS IRSA looks for when handing the pod temporary AWS credentials.
- A `ClusterRole` and `ClusterRoleBinding` granting **read-only** access cluster-wide. This is enough for the dashboard to list namespaces and read deployments, statefulsets, pods, services, configmaps, and secrets in any namespace. It cannot change anything. Pod logs are included so the deployment log view works.
- A namespace-scoped `Role` and `RoleBinding` in the release namespace granting access to `coordination.k8s.io` `Lease` objects for control-plane leader election.
- For each namespace you list in `control.rbac.writeNamespaces`, a namespace-scoped `Role` and `RoleBinding` granting **write** access (create, update, patch, delete) on the resources PgDog actually manages: deployments, statefulsets, services, configmaps, secrets, service accounts, roles, role bindings, and pod disruption budgets. Namespaces not on the list stay strictly read-only.

A typical setup grants write access only to the namespaces where you want PgDog clusters to live:

```yaml
control:
  rbac:
    create: true
    writeNamespaces:
      - pgdog-prod
      - pgdog-staging
```

In the above example, the dashboard can see workloads in every namespace, but it can only spin up or tear down PgDog deployments in `pgdog-prod` and `pgdog-staging`. Leaving `writeNamespaces` empty produces a fully read-only install. The dashboard still works, but the "deploy" actions will be rejected by the API server.

| Option | Description |
|-|-|
| `control.rbac.create` | Render the ServiceAccount and the RBAC bindings. When `false`, no RBAC is rendered and the pod runs without a mounted API token. The Kubernetes views in the dashboard will be empty (bool, default `true`). |
| `control.rbac.serviceAccountName` | Override the generated ServiceAccount name. Empty falls back to `<release>-control` (string, default `""`). |
| `control.rbac.writeNamespaces` | Namespaces where the control plane is allowed to manage PgDog workloads. Each entry produces one Role + RoleBinding pair. Empty means the install is read-only everywhere (list, default `[]`). |

### Disabling RBAC

If your cluster manages RBAC out-of-band (a platform team's controller, GitOps, an admission policy), set `control.rbac.create: false`. The chart then renders no ServiceAccount, no ClusterRole/Binding, and no Role/Bindings, and the deployment runs the pod with `automountServiceAccountToken: false`. The dashboard still serves the UI, but every Kubernetes-backed view will be empty until you bind an externally-managed ServiceAccount with equivalent permissions to the pod yourself.

## AWS access (EKS / IRSA)

The control plane reads RDS topology and CloudWatch metrics so the dashboard can show your databases alongside the PgDog workloads. To do that in EKS without baking long-lived keys into the cluster, the recommended path is **IRSA** (IAM Roles for Service Accounts).

This needs three things, only one of which is in the chart:

1. **An OIDC provider for the cluster, registered in IAM.** This is a one-time per-cluster setup (`eksctl utils associate-iam-oidc-provider --cluster <name> --approve`, or the equivalent Terraform / console steps).
2. **An IAM role** whose trust policy lets the pod's ServiceAccount assume it, with a permissions policy granting read access to RDS and CloudWatch. Details below.
3. **`control.aws.roleArn`** set to that role's ARN. The chart annotates the ServiceAccount with `eks.amazonaws.com/role-arn: <roleArn>`, and the rest happens automatically inside the pod.

### Trust policy

The role must trust the cluster's OIDC provider and scope the trust to the control plane's ServiceAccount. That subject is `system:serviceaccount:<release-namespace>:<release>-control`, or whatever `control.rbac.serviceAccountName` is if you overrode it. Confirm the exact subject after `helm install` with:

```sh
kubectl -n <release-namespace> get sa \
  -l app.kubernetes.io/instance=<release>,app.kubernetes.io/component=control \
  -o name
```

The role's trust policy has to match the SA name byte-for-byte. An off-by-one here surfaces as `AccessDenied: Not authorized to perform sts:AssumeRoleWithWebIdentity` in the pod logs. Replace the account ID, region, and OIDC ID with your own:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::111111111111:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE:sub": "system:serviceaccount:default:control-control",
          "oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
```

The `:sub` condition is what keeps any other pod in the cluster from assuming this role. Leaving it off would let any ServiceAccount with the OIDC trust pick it up.

#### Generating the trust policy

Rather than hand-edit the JSON, you can derive every field from the live cluster with `aws` and `kubectl`. Set the four inputs at the top, then pipe the output straight into `aws iam create-role` or save it to a file:

```sh
CLUSTER=eks-prod
REGION=us-west-2
NAMESPACE=pgdog
RELEASE=pgdog-control

OIDC_HOST=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
  --query 'cluster.identity.oidc.issuer' --output text | sed 's|^https://||')
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
SA=$(kubectl -n "$NAMESPACE" get sa \
  -l app.kubernetes.io/instance="$RELEASE",app.kubernetes.io/component=control \
  -o jsonpath='{.items[0].metadata.name}')

cat > trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_HOST}:sub": "system:serviceaccount:${NAMESPACE}:${SA}",
          "${OIDC_HOST}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF
```

Then create (or update) the role:

```sh
# First-time creation
aws iam create-role \
  --role-name pgdog-control \
  --assume-role-policy-document file://trust-policy.json

# Updating an existing role's trust policy in place
aws iam update-assume-role-policy \
  --role-name pgdog-control \
  --policy-document file://trust-policy.json
```

The `kubectl` lookup only works after `helm install` has run. The SA doesn't exist yet on a fresh cluster. If you're bootstrapping in the other order (role first, then chart), substitute the SA name manually: `SA="${RELEASE}-control"`.

### Permissions policy

The control plane only reads from AWS. It never creates, modifies, or deletes anything. A minimal policy covering the APIs it actually calls:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "RDSTopology",
      "Effect": "Allow",
      "Action": [
        "rds:DescribeDBClusters",
        "rds:DescribeDBInstances",
        "rds:DescribeDBParameters"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EC2InstanceTypes",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstanceTypes"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudWatchMetrics",
      "Effect": "Allow",
      "Action": [
        "cloudwatch:GetMetricData",
        "cloudwatch:GetMetricStatistics",
        "cloudwatch:ListMetrics"
      ],
      "Resource": "*"
    }
  ]
}
```

The control plane calls `rds:DescribeDBParameters` to display parameter-group settings for each instance, and `ec2:DescribeInstanceTypes` to look up the vCPU/memory specs of the underlying instance class (e.g. `db.r6g.xlarge` → 4 vCPU, 32 GiB). Without these two actions the RDS refresh fails with `AccessDenied` / `UnauthorizedOperation` and the database panel stays empty.

If you want to lock it down further, both `rds:Describe*` actions support resource-level ARNs and you can scope CloudWatch via the `cloudwatch:namespace` condition key set to `AWS/RDS`.

### Wiring it up

Once the role exists, point the chart at it:

```yaml
control:
  aws:
    roleArn: arn:aws:iam::111111111111:role/pgdog-control
    region: us-east-1
```

`region` is emitted as `AWS_REGION` on the container and is required unless the pod runs on a node whose IMDS already exposes one. For clusters without IRSA (kind, minikube, a non-EKS managed cluster), set `control.aws.accessKeyId` / `secretAccessKey` instead. The chart will render a `<release>-aws-creds` Secret and load it via `envFrom`. Don't do this on EKS; IRSA is strictly better.

| Option | Description |
|-|-|
| `control.aws.roleArn` | IAM role ARN. When non-empty, annotates the ServiceAccount with `eks.amazonaws.com/role-arn` so the EKS pod-identity webhook can inject `AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE` (string, default `""`). |
| `control.aws.region` | AWS region the SDK targets. Rendered as `AWS_REGION` on the container (string, default `""`). |
| `control.aws.accessKeyId` / `secretAccessKey` / `sessionToken` | Static IAM-user credentials. Only for non-EKS clusters. Don't set these alongside `roleArn`; pick one (string, default `""`). |

## Configuration

The control plane reads its runtime configuration from a TOML file at `/etc/pgdog-control/control.toml`. The chart materializes that file from `control.config` in `values.yaml`. Every nested key under `control.config` becomes a TOML table, and field names map straight through. Every section and every field is optional; anything you omit falls back to a hardcoded default, so a minimal install only sets the handful of values.

Each subsection below covers one TOML section.

### PgDog API IP Allowlist

`control.config.api.pgdog.ip_allowlist` adds an optional source-IP gate in front of the PgDog machine API endpoints under `/api/v2/*`. It is disabled by default. When enabled, the control plane accepts those requests only when the direct TCP peer address falls inside one of the configured CIDR ranges:

```yaml
control:
  config:
    api:
      pgdog:
        ip_allowlist:
          enabled: true
          allowed_cidrs:
            - 10.0.0.0/8
            - 172.16.0.0/12
            - 192.168.0.0/16
            - 127.0.0.0/8
            - ::1/128
            - fc00::/7
```

If `allowed_cidrs` is omitted, the control plane defaults to private IPv4 ranges, IPv4/IPv6 loopback, and IPv6 ULA. The check intentionally uses the direct TCP peer address and ignores forwarded headers such as `X-Forwarded-For`; configure the CIDRs for the address the control plane actually sees from your ingress, load balancer, sidecar, or PgDog caller.

| Option | Description |
|-|-|
| `api.pgdog.ip_allowlist.enabled` | Enables source-IP checks for `/api/v2/*` PgDog endpoints (bool, default `false`). |
| `api.pgdog.ip_allowlist.allowed_cidrs` | CIDR ranges allowed to call `/api/v2/*`. Invalid CIDRs cause protected requests to be rejected until the config is fixed (list of strings, default private IPv4 ranges, loopback, and IPv6 ULA). |

### Authentication

`control.config.auth` wires up the OAuth-backed login flow for the dashboard. GitHub and Google are supported and can be enabled side by side. At least one needs to be configured, or the dashboard will be **accessible by anyone with the URL**:

```yaml
control:
  config:
    auth:
      redirect_base_url: https://control.acme.com
      cookie_secure: true
      session_max_age_days: 30
      github:
        client_id: Iv1.0123456789abcdef
        client_secret: shhh
        allowed_orgs: [acme-corp]
      google:
        client_id: 0123456789-abc.apps.googleusercontent.com
        client_secret: shhh
        allowed_domains: [acme.com]
```

| Option | Description |
|-|-|
| `redirect_base_url` | Public base URL of the dashboard. Used to build the OAuth redirect URI registered with each provider, e.g. `https://control.acme.com/auth/github/callback`. Defaults to `http://localhost:8080` (string, optional). |
| `cookie_secret` | Master key used to sign the session and CSRF cookies. **Leave empty in production.** The chart generates a random 64-character key on first install and stores it in a `<release>-secrets` Secret, then reuses it on every `helm upgrade` via a `lookup` call so sessions survive rollouts. Setting this explicitly disables the helper Secret (string, optional). |
| `cookie_secure` | Set the `Secure` flag on cookies. Disable only for local HTTP testing (bool, default `true`). |
| `session_max_age_days` | Lifetime of the signed session cookie (int, default `30`). |
| `state_max_age_min` | Lifetime of the per-request CSRF state cookie. Has to outlive the user clicking through the provider's consent screen (int, default `10`). |
| `github.client_id` / `github.client_secret` | OAuth credentials from the GitHub App. Required to enable the GitHub login route. |
| `github.allowed_orgs` | If non-empty, only users whose membership the GitHub API reports in one of these orgs are allowed to log in. The `read:org` scope is added automatically when this list is non-empty (list of strings, default `[]`). |
| `google.client_id` / `google.client_secret` | OAuth credentials from the Google Cloud OAuth client. Required to enable the Google login route. |
| `google.allowed_domains` | If non-empty, only users whose verified Google email's domain (the part after `@`, compared case-insensitively) appears in this list are allowed to log in (list of strings, default `[]`). |

#### Sourcing OAuth credentials from a Secret

Inlining `client_id` / `client_secret` above writes them in plaintext into the `<release>-control-config` ConfigMap. To keep the client secrets out of the ConfigMap (and out of your values), reference an existing `Secret` in the release namespace instead. The chart injects each referenced key as an environment variable (`GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`) via `secretKeyRef`; the control plane reads these when the corresponding field is absent from `control.toml`.

```sh
kubectl create secret generic oauth-secrets \
  --from-literal=github-client-secret=shhh \
  --from-literal=google-client-secret=shhh
```

```yaml
control:
  config:
    auth:
      redirect_base_url: https://control.acme.com
      github:
        client_id: Iv1.0123456789abcdef   # not sensitive — fine to inline
        allowed_orgs: [acme-corp]
        secret:
          name: oauth-secrets
          clientSecretKey: github-client-secret
      google:
        client_id: 0123456789-abc.apps.googleusercontent.com
        allowed_domains: [acme.com]
        secret:
          name: oauth-secrets
          clientSecretKey: google-client-secret
```

| Option | Description |
|-|-|
| `<provider>.secret.name` | Name of an existing `Secret` in the release namespace holding the credentials. Required when either key below is set (string, optional). |
| `<provider>.secret.clientIdKey` | Key in that Secret to inject as `GITHUB_CLIENT_ID` / `GOOGLE_CLIENT_ID`. Leave `client_id` unset when this is set (string, optional). |
| `<provider>.secret.clientSecretKey` | Key in that Secret to inject as `GITHUB_CLIENT_SECRET` / `GOOGLE_CLIENT_SECRET`. Leave `client_secret` unset when this is set (string, optional). |

The provider's `[auth.<provider>]` section still has to render for the login route to be enabled, so keep at least one inline field (`client_id`, `allowed_orgs`/`allowed_domains`) or the `secret` block set under the provider. Env vars sourced this way are not hashed into the deployment's `checksum/config` annotation — rotating the referenced Secret needs a manual `kubectl rollout restart deployment/<release>-control`.

### Helm

When the dashboard provisions a new PgDog cluster, it shells out to `helm upgrade --install` against a chart fetched from our Helm repository. `control.config.helm` controls which chart and which repository. The defaults point at the public `pgdogdev` chart on `helm.pgdog.dev`, which is what you want unless you mirror the chart internally.

```yaml
control:
  config:
    helm:
      chart: pgdog
      repo: pgdogdev
      repo_url: https://helm.pgdog.dev
```

| Option | Description |
|-|-|
| `chart` | Chart name within the repo. The control plane installs `{repo}/{chart}` (string, default `pgdog`). |
| `repo` | Locally-registered repo name. Used both as the prefix in the chart reference and as the name passed to `helm repo add` (string, default `pgdogdev`). |
| `repo_url` | Repo index URL. This is what `helm repo add <repo> <repo_url>` is pointed at on boot, so the dashboard doesn't need an out-of-band `helm repo add` step (string, default `https://helm.pgdog.dev`). |

### Background polling

The dashboard refreshes its view of the world by polling each backing system on a fixed cadence. Defaults are tuned for production; lower them if you want faster updates at the cost of more API calls, or raise them if you're trying to stay under a rate limit. CloudWatch and RDS settings are no-ops unless AWS credentials are configured.

```yaml
control:
  config:
    rds:
      refresh_interval_secs: 60
      # Experimental: do not enable in production yet.
      autodiscovery: false
    kube:
      refresh_interval_secs: 15
    dns:
      refresh_interval_secs: 30
    cloudwatch:
      refresh_interval_secs: 60
      lookback_secs: 3600
      period_secs: 60
```

| Option | Description |
|-|-|
| `rds.refresh_interval_secs` | How often to poll AWS RDS for cluster and instance topology (int, default `60`). |
| `rds.autodiscovery` | **Experimental. Do not enable in production yet.** Automatically reconcile Helm-managed PgDog database entries from discovered RDS topology (bool, default `false`). |
| `kube.refresh_interval_secs` | How often to poll Kubernetes for PgDog workloads. Independent of the `watch` streams, which fire on events (int, default `15`). |
| `dns.refresh_interval_secs` | How often to re-resolve every known RDS hostname (int, default `30`). |
| `cloudwatch.refresh_interval_secs` | How often to poll CloudWatch for per-instance metrics (int, default `60`). |
| `cloudwatch.lookback_secs` | How far back each fetch reaches. A fresh deploy pulls the full window on its first tick (int, default `3600`). |
| `cloudwatch.period_secs` | CloudWatch aggregation period. The smallest bucket the metric API returns (int, default `60`). |

### Alerting

`control.config.alerts` enables outbound alert integrations. Leave `incident_io` unset to disable incident.io. Thresholds are optional and only configured metrics create alerts.

```yaml
control:
  config:
    alerts:
      evaluation_window_secs: 300
      thresholds:
        clients_waiting: 10
        cpu: 90.0
        memory: 2048
        server_connections: 100
      incident_io:
        api_key: inc_live_xxx
```

| Option | Description |
|-|-|
| `evaluation_window_secs` | How long metrics must remain at or above threshold before creating an alert (int, default `300`). |
| `thresholds.clients_waiting` | Number of clients waiting on a server connection (int, optional). |
| `thresholds.cpu` | CPU usage percentage. Must be between `0.0` and `100.0`, inclusive (float, optional). |
| `thresholds.memory` | Memory used, in megabytes (int, optional). |
| `thresholds.server_connections` | Number of open server connections (int, optional). |
| `incident_io.api_key` | incident.io API key with permission to create incidents. Missing `incident_io` disables the integration (string, optional). |

### State store

`control.config.store` governs the in-memory metric store: how often it sweeps for stale data, when an instance is marked stale or evicted, and how long per-instance metric history is retained. The defaults are tight enough for an interactive dashboard; widen them if you keep the UI open against a cluster that's intentionally idle, or if you want a longer historical window in memory.

```yaml
control:
  config:
    store:
      tick_secs: 1
      stale_after_secs: 5
      evict_after_secs: 60
      metrics_retention_secs: 300
      query_history_limit: 1000
      autoreload: immediately # or in_sync, or off
```

| Option | Description |
|-|-|
| `tick_secs` | How often the sweep task wakes up. Sets the shortest possible reaction time for stale and evict transitions (int, default `1`). |
| `stale_after_secs` | Instance is marked stale if its newest metric is older than this. The UI dims it but keeps it visible (int, default `5`). |
| `evict_after_secs` | Instance is dropped from the store entirely if its newest metric is older than this (int, default `60`). |
| `metrics_retention_secs` | How much per-instance metric history is kept in memory. Older points are dropped as new ones arrive (int, default `300`). |
| `query_history_limit` | Per-token historical query store capacity. Oldest deduped query entries are evicted first once the limit is reached (int, default `1000`). |
| `autoreload` | Automatically enqueue `reload_configuration` for instances that report config drift (enum, default `off`, available options: `off`, `immediately`, `in_sync`). |

### Slack Notifications

`control.config.slack` enables Slack status updates for long-running deployment and maintenance work. Leave either field empty to disable Slack. If the section is omitted, the control plane falls back to the `SLACK_BOT_TOKEN` and `SLACK_CHANNEL` environment variables.

```yaml
control:
  config:
    slack:
      bot_token: xoxb-...
      channel: C0123456789
```

| Option | Description |
|-|-|
| `bot_token` | Slack bot token with `chat:write` permission (string, optional). |
| `channel` | Slack channel ID or name for status updates (string, optional). |

### Redis persistence

`control.config.redis` controls how the in-memory store is snapshotted to Redis between process restarts. The chart already provisions an in-cluster Redis (`<release>-redis`) and the control plane points at it by default, so most installs leave this section alone.

```yaml
control:
  config:
    redis:
      url: redis://my-redis.cache:6379
      save_interval_secs: 60
```

| Option | Description |
|-|-|
| `url` | Redis connection string. Leave empty to use the in-cluster Redis the chart installs; set it only to point at an external Redis (string, optional). |
| `save_interval_secs` | How often the background task snapshots the store to Redis (int, default `60`). |

## Examples

```sh
helm install control pgdogdev-ee/pgdog-control -f values.yaml
```

### EKS with the AWS Load Balancer Controller

This example deploys into an EKS cluster that already has the AWS Load Balancer Controller, and TLS certificate set up via ACM. AWS credentials come from IRSA.

```yaml
control:
  aws:
    # IAM role assumed by the pod via IRSA. The role's trust policy must
    # allow system:serviceaccount:<release-ns>:<release>-control.
    roleArn: arn:aws:iam::111111111111:role/pgdog-control
    region: us-east-1
  rbac:
    create: true
    # Namespaces where the control plane is allowed to manage PgDog
    # clusters. The dashboard still sees workloads in every namespace.
    writeNamespaces:
      - pgdog-prod
      - pgdog-staging
  config:
    auth:
      redirect_base_url: https://control.acme.com
      github:
        client_id: Iv1.0123456789abcdef
        client_secret: shhh-store-this-in-a-secret
        allowed_orgs: [acme-corp]

ingress:
  enabled: true
  mode: aws
  host: control.acme.com
  aws:
    scheme: internet-facing
    certificateArn: arn:aws:acm:us-east-1:111111111111:certificate/abc-123-def-456
    sslRedirect: true
```

### Generic Kubernetes with ingress-nginx and cert-manager

This example targets a generic cluster (kubeadm, on-prem, or any managed Kubernetes) with [ingress-nginx](https://kubernetes.github.io/ingress-nginx/) handling traffic and [cert-manager](https://cert-manager.io/) issuing Let's Encrypt certificates.

```yaml
control:
  rbac:
    create: true
    writeNamespaces:
      - pgdog-prod
      - pgdog-staging
  config:
    auth:
      redirect_base_url: https://control.acme.com
      google:
        client_id: 0123456789-abc.apps.googleusercontent.com
        client_secret: shhh-store-this-in-a-secret
        allowed_domains: [acme.com]

ingress:
  enabled: true
  mode: nginx
  host: control.acme.com
  nginx:
    tls:
      enabled: true
    clusterIssuer: letsencrypt-prod
    sslRedirect: "true"
```

# Vault Deployment on Exoscale Scalable Kubernetes Service (SKS)

Demo of HashiCorp Vault deployment on Exoscale Scalable Kubernetes Service (SKS).

## Exoscale API Keys

Export the Exoscale API credentials to the environment:
```bash
export EXOSCALE_API_KEY=...
export EXOSCALE_API_SECRET=...
```

Optionally, include these credentials in the `.env` environment file that is also used further below.

## Kubeconfig

The Kubeconfig is generated as an output artifact.

Dowonload the apply job artifact as zip file `output.zip`.

Extract and use the kubeconfig as follows:
```bash
cat output.json | jq -r '.kubeconfig.value' > kubeconfig
chmod 600 kubeconfig
export KUBECONFIG=./kubeconfig
```

Alternatively, [access Terraform state](https://docs.gitlab.com/ee/user/infrastructure/iac/terraform_state.html#access-the-state-from-your-local-machine) from your local machine.

Retrieve the kubeconfig outputs:
```bash
terraform output -raw kubeconfig > kubeconfig
chmod 600 kubeconfig
export KUBECONFIG=./kubeconfig
```

## ArgoCD Bootstrapping

Deploy ArgoCD with Helm:
```bash
ARGO_NS=infra-argocd
kubectl create ns $ARGO_NS
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd \
  --namespace=$ARGO_NS \
  --set dex.enabled="false"
```

Access ArgoCD locally:
```bash
kubectl port-forward svc/argocd-server -n infra-argocd 8080:443
```

Retrieve the default admin password and login:
```bash
ARGOCD_ADMIN_PASSWORD=$(kubectl get secret argocd-initial-admin-secret -n infra-argocd -o jsonpath="{.data.password}" | base64 -d)
argocd login 127.0.0.1:8080 --username admin --password $ARGOCD_ADMIN_PASSWORD
```

Create a GitLab [Project Access Token (PAT)](https://docs.gitlab.com/ee/user/project/settings/project_access_tokens.html) for ArgoCD:
```bash
cat <<EOF > .env
GLPAT_USER=ArgoCD
GLPAT=glpat-***
EOF
```

Load the PAT into the current shell environment:
```bash
source .env
```

Add the GitLab repository to ArgoCD:
```bash
argocd repo add \
 https://github.com/adfinis/sks-vault-demo.git \
 --username $GLPAT_USER \
 --password $GLPAT \
 --insecure-skip-server-verification
```

The PAT will be stored inside a Kubernetes secret `repo-*` in the `infra-argocd` namespace:
```bash
kubectl get secret -n infra-argocd | grep repo
repo-217524524                           Opaque               5      39s
```

Add initial project:
```bash
argocd proj create argocd-apps \
 --src https://github.com/adfinis/sks-vault-demo.git \
 --dest https://kubernetes.default.svc,infra-argocd
```

Add first app:
```bash
argocd app create argocd-configs \
 --project argocd-apps \
 --sync-policy auto \
 --repo https://github.com/adfinis/sks-vault-demo.git \
 --path manifests \
 --dest-server https://kubernetes.default.svc \
 --dest-namespace infra-argocd
```

## Generate TLS Certificates for the Vault API

This repo includes a simple shell script to generate self-signed TLS certificates that can be used with the HashiCorp Vault server. Usage:

```bash
cd scripts
./vault-tls.sh
```

The script generates a set of of self-signed certificates that can be use for the Vault server API.

Import the certificate and key in the Kubernets cluster by registering a Secret with the contents of the certificate as follows:
```bash
# Retrieve vault.crt, key and CA cert as Kubernetes secrets
kubectl create secret generic vault-server-tls \
  --from-file=vault.key=scripts/tls/vault.key \
  --from-file=vault.crt=scripts/tls/vault.crt \
  --from-file=vault.ca=scripts/tls/vault_ca.crt \
  -n security-vault
```


## HashiCorp Vault Enterprise License

Order a trial license for evaluation purposes here:

https://vaultproject.io/trial

Create a Kubernetes secret `license` in the namespace for Vault so that the Vault server automatically uses that license key to start (see [license autoloading](https://developer.hashicorp.com/vault/docs/enterprise/license/autoloading)):
```bash
kubectl create secret generic vault-license \
  --from-file=license=vault.hclic \
  -n security-vault
```

## Accessing the Vault Pods

Example access to first Vault Pod:
```bash
kubectl exec -it vault-0 -n security-vault -- sh
```

Example port forwarding:
```bash
kubectl port-forward svc/vault -n security-vault 8200:8200
```

Example local environment for working with the Vault CLI:
```bash
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_CACERT=scripts/tls/vault_ca.crt
```

Example initialization:
```bash
kubectl exec -it vault-0 -n security-vault -- vault operator init # -key-shares=n -key-threshold=m
# restart unitialized Pods, make them aware of the new cluster status
kubectl delete po -n security-vault -l vault-initialized=false
```

Example unsealing:
```
kubectl exec -it vault-0 -n security-vault -- vault operator unseal
```

## Exoscale IAM Secrets Engine

This demo includes the [`vault-plugin-secrets-exoscale`](https://github.com/exoscale/vault-plugin-secrets-exoscale), a secrets engine for Vault to generate dynamic Exoscale IAM credentials.

[Configuration](https://github.com/exoscale/vault-plugin-secrets-exoscale#configuration) steps:
```bash
# Forward Vault API from within the SKS cluster to the local host
nohup kubectl port-forward svc/vault -n security-vault 8200:8200 &
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_CACERT=scripts/tls/vault_ca.crt

# get shasum of plugin binary on Vault server Pod
plugin_shasum=$(kubectl exec -it vault-0 -- sha256sum /usr/local/libexec/vault/vault-plugin-secrets-exoscale | cut -d " " -f 1)

# login with Token
vault login

# enable secrets engine plugin with that shasum
vault write sys/plugins/catalog/secret/exoscale \
  sha_256=$plugin_shasum \
  command="vault-plugin-secrets-exoscale"

# verify
vault list sys/plugins/catalog/secret | grep exo
exoscale

# enable secrets engine plugin
vault secrets enable -plugin-name="exoscale" plugin

# verify
vault secrets list
Path          Type         Accessor              Description
----          ----         --------              -----------
exoscale/     exoscale     exoscale_3f9a297c     n/a
```

[Usage](https://github.com/exoscale/vault-plugin-secrets-exoscale#usage):
```bash
vault write exoscale/config/root \
  root_api_key=$EXOSCALE_API_KEY \
  root_api_secret=$EXOSCALE_API_SECRET \
  zone=ch-dk-2
```

Keep TTLS short:
```bash
vault write exoscale/config/lease \
  ttl=3m \
  max_ttl=5m
```

Create a backend role:
```bash
vault write exoscale/role/list-only \
	operations=list-zones,list-instance-types \
  renewable=true
```

Get an API key:
```bash
vault read exoscale/apikey/list-only
```

Check the API keys in the Exoscale Portal.

Positive check of the allowed operation:
```bash
EXOSCALE_API_KEY=*** EXOSCALE_API_SECRET=*** exo zone
┼──────────────────────────────────────┼──────────┼
│                  ID                  │   NAME   │
┼──────────────────────────────────────┼──────────┼
│ 4da1b188-dcd6-4ff5-b7fd-bde984055548 │ at-vie-1 │
│ 70e5f8b1-0b2c-4457-a5e0-88bcf1f3db68 │ bg-sof-1 │
│ 91e5e9e4-c9ed-4b76-bee4-427004b3baf9 │ ch-dk-2  │
│ 1128bd56-b4d9-4ac6-a7b9-c715b187ce11 │ ch-gva-2 │
│ 35eb7739-d19e-45f7-a581-4687c54d6d02 │ de-fra-1 │
│ 85664334-0fd5-47bd-94a1-b4f40b1d2eb7 │ de-muc-1 │
┼──────────────────────────────────────┼──────────┼
```

Negative check of disallowed operation:
```bash
EXOSCALE_API_KEY=*** EXOSCALE_API_SECRET=*** exo compute sks list
warning: errors during listing, results might be incomplete.
6 errors occurred:
        * unable to list SKS clusters in zone ch-dk-2: Get "https://api-ch-dk-2.exoscale.com/v2/sks-cluster": invalid request: API Key is not authorized to perform the operation list-sks-clusters
        * unable to list SKS clusters in zone de-fra-1: Get "https://api-de-fra-1.exoscale.com/v2/sks-cluster": invalid request: API Key is not authorized to perform the operation list-sks-clusters
        * unable to list SKS clusters in zone ch-gva-2: Get "https://api-ch-gva-2.exoscale.com/v2/sks-cluster": invalid request: API Key is not authorized to perform the operation list-sks-clusters
        * unable to list SKS clusters in zone de-muc-1: Get "https://api-de-muc-1.exoscale.com/v2/sks-cluster": invalid request: API Key is not authorized to perform the operation list-sks-clusters
        * unable to list SKS clusters in zone at-vie-1: Get "https://api-at-vie-1.exoscale.com/v2/sks-cluster": invalid request: API Key is not authorized to perform the operation list-sks-clusters
        * unable to list SKS clusters in zone bg-sof-1: Get "https://api-bg-sof-1.exoscale.com/v2/sks-cluster": invalid request: API Key is not authorized to perform the operation list-sks-clusters
```

Check the leases in Vault:
```bash
vault list sys/leases/lookup/exoscale/apikey/list-only
Keys
----
kcVl0yArPZYHwu7bPRdO1chl
```

To revoke by prefix ("break glass" procedure in case of leaked secret for a role or engine):
```bash
vault write -f sys/leases/revoke-prefix/exoscale/apikey/list-only
```

Or simply wait until the TTL is 0.

## Limitations of the Demo Setup

* No auto-unsealing
* No persistent data storage and no audit logs
* No Ingress, Vault API is not exposed outside of this Kubernetes cluster
* No identity management and Vault policy
* Self-signed TLS certificate

## Links

* https://registry.terraform.io/modules/camptocamp/sks
* https://www.exoscale.com/syslog/easy-terraform-sks
* https://github.com/exoscale/vault-plugin-secrets-exoscale

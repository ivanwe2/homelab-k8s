# homelab-k8s

GitOps repo for my 3-node k3s homelab, managed by Argo CD (app-of-apps).

## Bootstrap (once per cluster)
1. helm install argocd argo/argo-cd -n argocd --create-namespace --version <x> -f bootstrap/argocd-values.yaml
2. kubectl apply -f bootstrap/root.yaml

Everything else is deployed by adding files under apps/.
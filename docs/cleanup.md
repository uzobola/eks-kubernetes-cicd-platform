# Platform Cleanup and Teardown

## Purpose

This runbook removes the EKS CI/CD and GitOps platform after implementation evidence has been captured.

The cleanup sequence matters. Several resources are created outside Terraform:

```text
Jenkins Helm release
Argo CD Application and install.yaml
AWS ALB created from Kubernetes Ingress
Cluster Autoscaler Helm release
Prometheus / Grafana Helm release
HPA load-generator pod
```

Those resources must be removed before destroying Terraform-managed AWS infrastructure.

Metrics Server is an EKS add-on owned by Terraform. Do not uninstall it with Helm.

Commands assume execution from the repository root unless stated otherwise.

Related docs: [Installation](installation.md) · [NHI inventory](nhi-governance-inventory.md) · [Security model](security-model.md) · [GitOps](gitops.md)

---

## Cleanup Flow

```text
Kubernetes / Helm / Argo resources
                |
                v
AWS-created ALB confirmed deleted
                |
                v
terraform/infrastructure
                |
                v
Verify EKS / EC2 / NAT / ALB / EIPs gone
                |
                v
Offboard external Git credentials
                |
                v
terraform/bootstrap
                |
                v
Final zero-resource verification
```

> Can a retired workload or automation system still authenticate to anything?

If yes, teardown is incomplete.

---

## 1. Preserve Project Evidence

Do not begin teardown until required screenshots and documentation are in Git.

Commit remaining documentation and evidence on `main` explicitly. Do not use `git add .`; that can pick up local notes, `docs/evidence/submission/`, or credentials.

```bash
git status
git add docs/ README.md
git commit -m "Finalize project documentation and evidence"
git push origin main
```

Confirm the `gitops` branch is pushed:

```bash
git checkout gitops
git status
git push origin gitops
git checkout main
```

Do not delete the `gitops` branch. It is retained as project evidence.

---

## 2. Capture the Current Runtime Inventory

Record Helm releases:

```bash
aws-vault exec terraform -- \
  helm list -A
```

Check the GitOps Application:

```bash
aws-vault exec terraform -- \
  kubectl get application challenge-app-gitops \
  -n argocd
```

Check application resources:

```bash
aws-vault exec terraform -- \
  kubectl get all,ingress,hpa \
  -n challenge-app
```

Check Ingress across the cluster:

```bash
aws-vault exec terraform -- \
  kubectl get ingress -A
```

Check AWS load balancers:

```bash
aws-vault exec terraform -- \
  aws elbv2 describe-load-balancers \
  --region us-east-1 \
  --query 'LoadBalancers[].{Name:LoadBalancerName,State:State.Code,DNS:DNSName}' \
  --output table
```

This inventory establishes what still needs to be removed.

---

## 3. Remove the Argo CD Application

Remove the GitOps Application before deleting Argo CD itself.

If it exists, configure cascading deletion:

```bash
aws-vault exec terraform -- \
  kubectl -n argocd patch application challenge-app-gitops \
  --type merge \
  -p '{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io"]}}'
```

Delete the Application:

```bash
aws-vault exec terraform -- \
  kubectl delete application challenge-app-gitops \
  -n argocd
```

If the delete hangs, the Application still has a finalizer and child resources. Wait, then re-check. Do not force-remove the finalizer unless the child resources are already gone.

Verify:

```bash
aws-vault exec terraform -- \
  kubectl get application challenge-app-gitops \
  -n argocd
```

Expected:

```text
NotFound
```

---

## 4. Remove the Jenkins Helm Application Release

Argo CD resource deletion does not necessarily remove the Helm release record created earlier by Jenkins.

If a load-generator pod was applied during HPA testing, remove it:

```bash
aws-vault exec terraform -- \
  kubectl delete -f platform/tests/hpa-load-generator.yaml \
  --ignore-not-found
```

Check:

```bash
aws-vault exec terraform -- \
  helm list -n challenge-app
```

If the release still exists:

```bash
aws-vault exec terraform -- \
  helm uninstall challenge-app \
  -n challenge-app
```

Verify:

```bash
aws-vault exec terraform -- \
  helm list -n challenge-app
```

Expected:

```text
No challenge-app release
```

Check remaining application resources:

```bash
aws-vault exec terraform -- \
  kubectl get all,ingress,hpa \
  -n challenge-app
```

Expected:

```text
No resources found
```

---

## 5. Confirm the Ingress and AWS ALB Are Gone

This step occurs before removing the AWS Load Balancer Controller.

Check Kubernetes:

```bash
aws-vault exec terraform -- \
  kubectl get ingress -A
```

Expected:

```text
No resources found
```

AWS ALB deletion can take several minutes after the Ingress is removed. Re-check until the project load balancer is gone:

```bash
aws-vault exec terraform -- \
  aws elbv2 describe-load-balancers \
  --region us-east-1 \
  --query 'LoadBalancers[].{Name:LoadBalancerName,State:State.Code,DNS:DNSName}' \
  --output table
```

Controller-created target groups and security groups can linger briefly. Re-check if a later Terraform destroy hangs on VPC or security-group deletion:

```bash
aws-vault exec terraform -- \
  aws elbv2 describe-target-groups \
  --region us-east-1 \
  --query 'TargetGroups[].TargetGroupName' \
  --output table
```

Do not remove the AWS Load Balancer Controller while a project Ingress or ALB still requires cleanup.

---

## 6. Remove the Monitoring Stack

```bash
aws-vault exec terraform -- \
  helm list -n monitoring
```

If present:

```bash
aws-vault exec terraform -- \
  helm uninstall monitoring \
  -n monitoring
```

Delete the namespace:

```bash
aws-vault exec terraform -- \
  kubectl delete namespace monitoring \
  --ignore-not-found
```

Verify:

```bash
aws-vault exec terraform -- \
  kubectl get namespace monitoring
```

---

## 7. Remove Cluster Autoscaler

```bash
aws-vault exec terraform -- \
  helm list -n kube-system
```

If `cluster-autoscaler` is present:

```bash
aws-vault exec terraform -- \
  helm uninstall cluster-autoscaler \
  -n kube-system
```

---

## 8. Remove AWS Load Balancer Controller

Only after:

```text
Application Ingress removed
AWS ALB removed
```

Then:

```bash
aws-vault exec terraform -- \
  helm uninstall aws-load-balancer-controller \
  -n kube-system
```

---

## 9. Confirm No Helm Releases Remain

```bash
aws-vault exec terraform -- \
  helm list -A
```

Expected: no project-managed Helm releases.

---

## 10. Remove Argo CD

Argo CD was installed from the pinned upstream `v3.5.0` manifest.

Remove it using the same manifest:

```bash
aws-vault exec terraform -- \
  kubectl delete \
  -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.0/manifests/install.yaml
```

Remove the namespace:

```bash
aws-vault exec terraform -- \
  kubectl delete namespace argocd \
  --ignore-not-found
```

---

## 11. Remove Remaining Application Namespace

```bash
aws-vault exec terraform -- \
  kubectl delete namespace challenge-app \
  --ignore-not-found
```

Do not manually remove Terraform-managed EKS resources at this stage.

---

## 12. Final Kubernetes Pre-Destroy Check

```bash
aws-vault exec terraform -- \
  helm list -A
```

```bash
aws-vault exec terraform -- \
  kubectl get ingress -A
```

```bash
aws-vault exec terraform -- \
  kubectl get svc -A
```

```bash
aws-vault exec terraform -- \
  aws elbv2 describe-load-balancers \
  --region us-east-1 \
  --query 'LoadBalancers[].{Name:LoadBalancerName,State:State.Code}' \
  --output table
```

The project should have:

```text
No project Helm releases
No project Ingress
No project ALB
No challenge-app workload
No Argo CD Application
```

---

## 13. Review the Infrastructure Terraform Destroy Plan

The project uses two Terraform environments:

```text
terraform/bootstrap
    -> remote-state bucket and lock foundation

terraform/infrastructure
    -> VPC, EKS, Jenkins, IAM, ECR, networking, logging
```

Destroy `terraform/infrastructure` first. The remote state must remain available while that destroy runs.

Do not destroy bootstrap at this stage.

Initialize the same remote backend used during provisioning:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure init
```

Confirm the state is the expected project state:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure state list
```

Review the destroy plan:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure plan -destroy
```

Expected deletions include:

```text
Amazon EKS cluster and managed node group
Jenkins EC2, IAM role, and EKS access entry
VPC, subnets, NAT Gateways, Elastic IPs, security groups
VPC CNI, Load Balancer Controller, and Cluster Autoscaler IAM roles
GitHub Actions IAM role
ECR repository
VPC Flow Logs and CloudWatch resources
Ansible transport resources and execution role
```

The GitHub OIDC provider is a data lookup, not a resource created by this project. Do not delete the account GitHub OIDC provider.

---

## 14. Destroy the Infrastructure Terraform Environment

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure destroy
```

Review the final plan and approve only the expected project resources.

Wait for:

```text
Destroy complete!
```

Confirm the infrastructure state is empty, apart from anything intentionally retained:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure state list
```

---

## 15. Handle ECR Cleanup if Required

The application ECR repository does not use `force_delete`. If Terraform cannot delete the repository while images remain, list them:

```bash
aws-vault exec terraform -- \
  aws ecr list-images \
  --repository-name eks-kubernetes-cicd-app \
  --region us-east-1 \
  --output table
```

Delete remaining images by digest:

```bash
for digest in $(aws-vault exec terraform -- \
  aws ecr list-images \
  --repository-name eks-kubernetes-cicd-app \
  --region us-east-1 \
  --query 'imageIds[].imageDigest' \
  --output text); do
  aws-vault exec terraform -- \
    aws ecr batch-delete-image \
    --repository-name eks-kubernetes-cicd-app \
    --region us-east-1 \
    --image-ids imageDigest="$digest"
done
```

Verify the repository is empty, then rerun:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure destroy
```

---

## 16. Verify Billable AWS Resources Are Gone

### EKS

```bash
aws-vault exec terraform -- \
  aws eks list-clusters \
  --region us-east-1
```

The project cluster should not appear.

### EC2

```bash
aws-vault exec terraform -- \
  aws ec2 describe-instances \
  --region us-east-1 \
  --filters Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,Type:InstanceType}' \
  --output table
```

The Jenkins instance and EKS worker instances should be gone.

### NAT Gateways

```bash
aws-vault exec terraform -- \
  aws ec2 describe-nat-gateways \
  --region us-east-1 \
  --filter Name=state,Values=available,pending \
  --query 'NatGateways[].{Id:NatGatewayId,State:State}' \
  --output table
```

No project NAT Gateway should remain.

### Load Balancers

```bash
aws-vault exec terraform -- \
  aws elbv2 describe-load-balancers \
  --region us-east-1 \
  --query 'LoadBalancers[].{Name:LoadBalancerName,State:State.Code}' \
  --output table
```

No project ALB should remain.

### Elastic IPs

```bash
aws-vault exec terraform -- \
  aws ec2 describe-addresses \
  --region us-east-1 \
  --query 'Addresses[].{PublicIp:PublicIp,AllocationId:AllocationId,AssociationId:AssociationId}' \
  --output table
```

Project NAT Gateway EIPs should be released.

---

## 17. Offboard External Non-Human Identities

Infrastructure deletion is not the complete lifecycle event.

After final deployment evidence has been captured, review:

```text
GitHub repository
  -> Settings
  -> Deploy keys
```

Remove the project keys independently:

```text
Jenkins read-only checkout
Argo CD read-only GitOps
```

The GitHub Actions IAM role is Terraform-managed and disappears with infrastructure destroy.

No long-lived AWS access key was used for GitHub Actions.

See [NHI inventory](nhi-governance-inventory.md) for the full offboarding checklist.

---

## 18. Destroy the Terraform Bootstrap Environment Last

Destroy bootstrap only after:

```text
infrastructure terraform destroy completed
AWS platform resources verified absent
Remote state no longer needed for teardown
```

Inspect bootstrap state:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/bootstrap init
```

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/bootstrap state list
```

Review the destroy plan:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/bootstrap plan -destroy
```

The plan should contain only bootstrap / state infrastructure:

```text
Terraform state S3 bucket
Encryption, public-access block, versioning, bucket policy
Supporting bootstrap resources
```

The bootstrap configuration protects the state bucket:

```hcl
lifecycle {
  prevent_destroy = true
}
```

Terraform will refuse to destroy the bucket until that protection is removed **after** the main infrastructure has been destroyed and verified.

The bucket may still contain:

```text
Current Terraform state
State lock file
Previous object versions
```

Those objects or versions may need to be emptied before AWS permits bucket deletion. Retain any state you want to keep as evidence first.

After the protection is intentionally removed and the bucket is empty enough to delete:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/bootstrap plan -destroy
```

Then:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/bootstrap destroy
```

Wait for:

```text
Destroy complete!
```

---

## 19. Capture Teardown Evidence

Capture:

```text
terraform destroy
Destroy complete!
```

Optionally capture verification showing:

```text
Project EKS cluster       absent
Project NAT Gateways      absent
Project ALB               absent
Project EC2               absent
```

Store as:

```text
docs/evidence/infrastructure/platform-teardown-complete.png
```

---

## Cleanup Completion Checklist

```text
[ ] Final screenshots captured
[ ] main branch pushed
[ ] gitops branch pushed

[ ] Argo CD Application deleted
[ ] HPA load-generator pod deleted
[ ] Jenkins challenge-app Helm release deleted
[ ] challenge-app resources deleted
[ ] Kubernetes Ingress deleted
[ ] AWS ALB deleted

[ ] Monitoring Helm release deleted
[ ] Cluster Autoscaler Helm release deleted
[ ] AWS Load Balancer Controller Helm release deleted
[ ] Argo CD deleted
[ ] challenge-app namespace deleted

[ ] helm list -A reviewed
[ ] terraform/infrastructure plan -destroy reviewed
[ ] terraform/infrastructure destroy completed

[ ] EKS cluster absent
[ ] Jenkins EC2 absent
[ ] EKS worker instances absent
[ ] NAT Gateways absent
[ ] ALB absent
[ ] project Elastic IPs released

[ ] Jenkins Git deploy key revoked
[ ] Argo CD Git deploy key revoked

[ ] Bootstrap destroyed only after state is no longer required
  or state bucket retained intentionally
[ ] Teardown evidence stored
```

---

## Lifecycle Principle

Deleting compute is not the same as completing offboarding.

A complete platform teardown removes:

```text
Workloads
Infrastructure
Load balancers
Runtime controllers
Cloud permissions
Federated IAM roles
Machine credentials
External deploy keys
```

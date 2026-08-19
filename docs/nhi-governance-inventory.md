# Non-Human Identity Governance Inventory

## Purpose

This document inventories the significant non-human identities used by the EKS Kubernetes CI/CD platform.

The platform contains several automation systems, controllers, workload identities, cloud roles, Git credentials, and service accounts.

The goal is not simply to list credentials.

The inventory records:

- Identity purpose
- Technical owner
- Identity type
- Authentication mechanism
- Trust relationship
- Granted authority
- Authority intentionally withheld
- Credential location
- Evidence
- Rotation or replacement model
- Offboarding action

The guiding principle is:

> An identity should exist only when a workload or automation process needs one, and its authority should be limited to the function it performs.

Related docs: [Architecture](architecture.md) · [Security model](security-model.md) · [CI/CD](cicd-pipeline.md) · [GitOps](gitops.md)

---

## Identity Governance Model

Every non-human identity is evaluated through six questions.

```text
1. What system or workload owns this identity?

2. Why does the identity exist?

3. What resource or trust domain does it authenticate to?

4. What authority does it receive?

5. What authority is deliberately withheld?

6. What actions remove the identity when it is no longer required?
```

This distinguishes identity lifecycle from workload lifecycle.

Deleting a workload does not always remove its cloud trust relationships, Git credentials, IAM roles, or Kubernetes permissions.

Likewise, removing one credential does not automatically remove the workload that used it.

---

## Identity Categories

The project contains several categories of non-human identity.

| Category                             | Examples                                                     |
| ------------------------------------ | ------------------------------------------------------------ |
| AWS IAM roles                        | Jenkins role, GitHub Actions role                            |
| Kubernetes workload identities       | Application ServiceAccount                                   |
| IRSA identities                      | VPC CNI, AWS Load Balancer Controller, Cluster Autoscaler    |
| Git machine credentials              | Jenkins deploy key, Argo CD deploy key                       |
| CI/CD platform identities            | Jenkins execution identity, GitHub Actions workflow identity |
| Infrastructure automation identities | Terraform execution role, Ansible execution role             |
| Kubernetes reconciliation identities | Argo CD service accounts                                     |
| Node identities                      | EKS managed node IAM role                                    |

---

## Inventory Summary

| Identity                      | Type                  | Primary Purpose             | AWS Authority                | Kubernetes Authority                   | Git Authority    |
| ----------------------------- | --------------------- | --------------------------- | ---------------------------- | -------------------------------------- | ---------------- |
| TerraformExecutionRole        | AWS IAM role          | Provision infrastructure    | Broad project provisioning   | Cluster admin through EKS access entry | None             |
| Ansible execution role        | AWS IAM role          | Configure Jenkins host      | SSM + temporary S3 transport | None                                   | None             |
| Jenkins EC2 role              | AWS IAM role          | CI/CD AWS operations        | ECR + EKS discovery          | Via separate EKS/RBAC mapping          | None             |
| Jenkins Git deploy key        | SSH deploy key        | Checkout private repository | None                         | None                                   | Read-only        |
| GitHub Actions role           | AWS IAM role via OIDC | Publish GitOps image        | ECR publishing               | None                                   | None             |
| GitHub Actions workflow token | GitHub token          | Update desired state        | None                         | None                                   | Repository write |
| Argo CD deploy key            | SSH deploy key        | Read Git desired state      | None                         | None                                   | Read-only        |
| Application ServiceAccount    | Kubernetes identity   | Pod identity                | None                         | Minimal workload identity              | None             |
| VPC CNI role                  | IRSA IAM role         | Pod networking              | AWS networking APIs          | CNI controller                         | None             |
| Load Balancer Controller role | IRSA IAM role         | Manage ALB resources        | Load-balancing APIs          | Ingress controller                     | None             |
| Cluster Autoscaler role       | IRSA IAM role         | Adjust worker capacity      | Auto Scaling APIs            | Autoscaling controller                 | None             |
| EKS node role                 | AWS IAM role          | Worker-node operation       | Worker + ECR pull            | Node identity                          | None             |

---

## Inventory Entries

### 1. Terraform Execution Role

| Field | Value |
| ----- | ----- |
| Identity | `TerraformExecutionRole` |
| Type | AWS IAM role |
| Owner | Infrastructure administration / Terraform |

#### Purpose

The role provisions and manages the AWS infrastructure required by the platform.

Examples include:

```text
VPC
Subnets
NAT Gateways
EKS
IAM roles
ECR
Jenkins EC2
Security groups
S3 infrastructure
Logging resources
```

#### Authentication

The administrator assumes the role through AWS Vault.

```text
Human operator
      |
      v
AWS Vault profile
      |
      v
STS AssumeRole
      |
      v
TerraformExecutionRole
```

Long-lived administrative credentials are not embedded in Terraform files.

#### Authority

The role requires broad infrastructure-management permissions within the AWS account for the resources provisioned by the project.

It is also registered as the stable EKS administrative principal through an EKS access entry.

#### Authority Withheld

The role is not used by application workloads or CI/CD runtime processes.

Application containers never inherit this identity.

#### Credential Location

```text
AWS IAM / temporary STS session
```

#### Evidence

Examples:

- Terraform apply output
- EKS access-entry validation
- AWS STS identity checks

#### Rotation / Replacement

The role itself does not use a static access key.

Rotation occurs at the credentials used by the human source principal or by replacing the role trust relationship.

#### Offboarding

```text
Remove EKS access entry
Remove role trust
Remove attached permissions
Delete role when infrastructure administration no longer requires it
```

Offboarding must account for Terraform state and any infrastructure still managed by the role.

---

### 2. Ansible Execution Role

| Field | Value |
| ----- | ----- |
| Identity | `eks-kubernetes-cicd-ansible-execution-role` |
| Type | AWS IAM role |
| Owner | Jenkins host configuration automation |

#### Purpose

The role lets Ansible configure the Jenkins EC2 instance without opening inbound SSH.

#### Authentication

A trusted human IAM principal assumes the role.

```text
Human IAM identity
       |
       v
STS AssumeRole
       |
       v
Ansible execution role
```

#### Authority

The role can perform operations required for:

```text
SSM session initiation
SSM session lifecycle
Jenkins instance discovery
Temporary Ansible S3 transport
```

The S3 transport permissions are restricted to the project Ansible transport bucket.

SSM session start is restricted to the Jenkins instance and required SSM session documents.

#### Authority Withheld

The role does not receive:

```text
EKS deployment authority
ECR publishing authority
Cluster administration
Broad EC2 mutation authority
```

#### Credential Location

```text
Temporary AWS STS session
```

#### Evidence

- `docs/evidence/security/ansible-execution-role-assumption.png`
- `docs/evidence/security/ansible-ssm-connectivity.png`

#### Rotation / Replacement

No long-lived role credential exists.

Trust can be moved to another administrative principal without modifying the Jenkins host.

#### Offboarding

```text
Remove role trust
Delete policy attachment
Delete role
Remove temporary transport bucket if no longer needed
```

Any active SSM sessions should be terminated during retirement.

---

### 3. Jenkins EC2 IAM Role

| Field | Value |
| ----- | ----- |
| Identity | `eks-kubernetes-cicd-jenkins-role` |
| Type | AWS IAM role attached through EC2 instance profile |
| Owner | Jenkins CI/CD controller |

#### Purpose

Jenkins uses this role for AWS operations performed by the traditional CI/CD pipeline.

#### Authentication

```text
Jenkins process
      |
      v
EC2 instance metadata
      |
      v
Temporary role credentials
      |
      v
AWS APIs
```

No AWS access key or secret access key is stored in Jenkins.

#### Authority

The role can:

```text
Authenticate to ECR
Push application images
Read image metadata
Describe the EKS cluster
```

An EKS access entry maps the IAM role to:

```text
jenkins-deployers
```

Kubernetes RBAC grants the actual application deployment authority.

#### Authority Withheld

Jenkins does not receive:

```text
Cluster-admin
Node deletion
kube-system administration
Unrelated ECR repository access
```

The distinction is:

```text
AWS IAM role
    -> cloud authentication


EKS access entry
    -> EKS authentication


Kubernetes RBAC
    -> Kubernetes authorization
```

#### Credential Location

```text
EC2 IAM instance profile
```

#### Evidence

- `docs/evidence/security/jenkins-kubernetes-rbac-boundary.png`
- `docs/evidence/cicd/jenkins-full-pipeline-success.png`

#### Rotation / Replacement

The role itself has no static credential.

Replacement can occur by:

```text
Create replacement IAM role
Attach required policy
Update instance profile
Update EKS access entry
Validate Kubernetes RBAC
Remove old role
```

#### Offboarding

A complete Jenkins AWS offboarding requires:

```text
Remove EKS access entry
Remove IAM policy attachment
Remove instance profile relationship
Delete IAM role
```

Removing only the Jenkins EC2 instance would not remove the IAM role or Kubernetes access mapping.

---

### 4. Jenkins Git Deploy Key

| Field | Value |
| ----- | ----- |
| Identity | Jenkins read-only checkout |
| Type | SSH deploy key |
| Owner | Jenkins |

#### Purpose

Allows Jenkins to clone the private project repository.

#### Authentication Target

```text
GitHub repository: eks-kubernetes-cicd-platform
```

#### Authority

```text
Repository read: YES
Repository write: NO
```

#### Authority Withheld

The key has no:

```text
AWS authority
Kubernetes authority
Repository write authority
Access to other repositories
```

#### Credential Location

```text
Public key:  GitHub repository deploy-key configuration
Private key: Jenkins credential store
```

The private key is not committed to Git.

#### Evidence

- `docs/evidence/security/cicd-git-identity-separation.png`
- `docs/evidence/cicd/jenkins-private-repo-pipeline-success.png`

#### Rotation / Replacement

```text
Generate new key pair
Add new public deploy key
Replace private key in Jenkins credential
Validate checkout
Remove old deploy key
Destroy old private key
```

#### Offboarding

```text
Remove deploy key from GitHub
Remove private key from Jenkins
Remove associated Jenkins credential
```

The GitHub entry and Jenkins-side private credential should both be removed.

---

### 5. GitHub Actions OIDC Identity

| Field | Value |
| ----- | ----- |
| Identity | GitHub Actions OIDC workload identity |
| Type | Federated workload identity |
| Owner | GitHub Actions GitOps pipeline |

#### Purpose

Allows the GitHub Actions workflow to authenticate to AWS without storing AWS access keys.

#### Authentication Flow

```text
GitHub Actions runner
        |
        v
GitHub OIDC token
        |
        v
AWS IAM OIDC provider
        |
        v
IAM trust evaluation
        |
        v
STS temporary credentials
```

#### Trust Boundary

Trust is restricted to:

```text
Expected GitHub owner
Expected repository
gitops branch
AWS STS audience
```

The project uses the repository's immutable GitHub OIDC subject format.

#### Authority

The federated identity may assume:

```text
eks-kubernetes-cicd-github-actions-role
```

only when the trust conditions match.

#### Authority Withheld

A token from an unrelated repository or branch must not be able to assume the role.

#### Credential Location

No static AWS credential exists.

The OIDC token and STS credentials are short-lived workflow credentials.

#### Evidence

- `docs/evidence/gitops/github-actions-gitops-success.png`

#### Rotation / Replacement

There is no static secret to rotate.

Trust lifecycle is controlled through:

```text
IAM role trust policy
Repository identity
Branch condition
OIDC provider
```

#### Offboarding

```text
Remove IAM trust relationship
Delete GitHub Actions IAM role if unused
Remove workflow
```

No access key cleanup is required.

---

### 6. GitHub Actions IAM Role

| Field | Value |
| ----- | ----- |
| Identity | `eks-kubernetes-cicd-github-actions-role` |
| Type | AWS IAM role assumed through OIDC |
| Owner | GitHub Actions GitOps build pipeline |

#### Purpose

Publishes application artifacts to Amazon ECR.

#### Authority

The role can:

```text
Authenticate to ECR
Upload application image layers
Publish application images
Read application image metadata
```

Repository-scoped image operations are limited to:

```text
eks-kubernetes-cicd-app
```

#### Authority Withheld

The role has:

```text
EKS deployment authority: NO
EKS access entry:          NO
Kubernetes RBAC:           NO
```

This is one of the primary GitOps trust boundaries.

GitHub Actions produces the artifact.

Argo CD deploys the artifact.

#### Credential Location

```text
Temporary STS session
```

#### Evidence

- `docs/evidence/gitops/github-actions-gitops-success.png`

#### Rotation / Replacement

The role uses no static credentials.

Replacement consists of creating a new role, changing the trust and workflow role ARN, validating federation, then deleting the old role.

#### Offboarding

```text
Remove trust
Remove policy attachment
Delete IAM role
Remove role reference from workflow
```

---

### 7. GitHub Actions Repository Token

| Field | Value |
| ----- | ----- |
| Identity | GitHub Actions workflow repository token |
| Type | Short-lived GitHub automation token |
| Owner | GitHub Actions workflow |

#### Purpose

Allows the workflow to commit the new immutable image tag into Git desired state.

#### Authority

The workflow grants:

```text
contents: write
```

for the desired-state update.

#### Authority Withheld

This GitHub credential has no AWS IAM authority by itself.

AWS access is established separately through OIDC.

```text
GitHub token
    -> Git authority


OIDC + STS role
    -> AWS authority
```

#### Credential Location

Generated by GitHub for the workflow run.

It is not stored in the repository.

#### Rotation / Replacement

Issued per workflow execution.

No manual secret rotation is required.

#### Offboarding

Remove the workflow or remove its `contents: write` permission.

---

### 8. Argo CD Git Deploy Key

| Field | Value |
| ----- | ----- |
| Identity | Argo CD read-only GitOps |
| Type | SSH deploy key |
| Owner | Argo CD |

#### Purpose

Allows Argo CD to read the private repository containing the gitops desired state.

#### Authentication Target

```text
GitHub repository: eks-kubernetes-cicd-platform
```

#### Authority

```text
Repository read: YES
Repository write: NO
```

#### Authority Withheld

The deploy key cannot:

```text
Modify desired state
Push commits
Publish ECR images
Call AWS APIs
```

#### Credential Location

```text
Public key:  GitHub repository deploy-key configuration
Private key: Kubernetes Secret in argocd namespace
```

#### Evidence

- `docs/evidence/security/cicd-git-identity-separation.png`
- `docs/evidence/gitops/argocd-synced-healthy.png`

#### Rotation / Replacement

```text
Generate replacement key
Add public key to GitHub
Update Argo repository credential Secret
Validate repository connectivity
Remove old deploy key
Destroy old private key
```

#### Offboarding

```text
Delete GitHub deploy key
Delete Argo repository credential Secret
Remove repository configuration if unused
```

Removing the Argo Application alone does not revoke the Git credential.

---

### 9. Argo CD Kubernetes Identities

| Field | Value |
| ----- | ----- |
| Identity | Argo CD service accounts |
| Type | Kubernetes service accounts |
| Owner | Argo CD platform |

#### Purpose

Argo CD components use Kubernetes identities to perform reconciliation and platform functions.

Examples include identities associated with:

```text
application-controller
repo-server
server
applicationset-controller
notifications-controller
```

#### Authentication Target

```text
Kubernetes API
```

#### Authority

Authority varies by Argo CD component.

The application controller performs the cluster reconciliation required for GitOps.

#### Authority Withheld

Argo's Git deploy key and Kubernetes identity are separate credentials.

```text
Git deploy key
    -> read repository


Kubernetes service account
    -> interact with Kubernetes API
```

Reading Git does not itself grant Kubernetes authority.

#### Credential Location

Kubernetes service-account identities inside the `argocd` namespace.

#### Rotation / Replacement

Managed through Kubernetes and Argo CD lifecycle operations rather than static human-managed cloud keys.

#### Offboarding

Full Argo retirement requires more than deleting its Git deploy key.

```text
Delete Argo Applications
Remove repository credential
Remove deploy key
Remove Argo CD workloads
Remove Argo service accounts and RBAC
Delete argocd namespace if the platform is fully retired
```

---

### 10. Application ServiceAccount

| Field | Value |
| ----- | ----- |
| Identity | `challenge-app` |
| Type | Kubernetes ServiceAccount |
| Owner | Flask application workload |

#### Purpose

Provides Kubernetes workload identity for the application pod.

#### AWS Authority

```text
NONE
```

The application does not call AWS APIs.

No IAM role is associated with the ServiceAccount.

#### Kubernetes API Credential

The pod uses:

```text
automountServiceAccountToken: false
```

The application therefore does not automatically receive a Kubernetes API bearer token.

#### Authority Withheld

```text
AWS permissions:           NONE
Kubernetes API token:      NOT AUTOMOUNTED
Cloud role assumption:     NONE
```

This is an example of an identity that exists while carrying almost no operational authority.

#### Evidence

- `docs/evidence/security/application-workload-identity-controls.png`
- `docs/evidence/security/application-serviceaccount-no-aws-role.png`
- `docs/evidence/security/no-serviceaccount-token.png`

#### Rotation / Replacement

There is no AWS credential to rotate.

The ServiceAccount is recreated through Helm/Kubernetes deployment lifecycle.

#### Offboarding

Workload retirement should include:

```text
Remove Deployment
Remove Service
Remove Ingress
Remove HPA
Remove ServiceAccount
Confirm no IAM trust references the ServiceAccount
```

For this application, the final IAM-trust check should return nothing, since no IRSA role exists for it.

---

### 11. VPC CNI Identity

| Field | Value |
| ----- | ----- |
| Identity | `eks-kubernetes-cicd-vpc-cni-role` |
| Type | AWS IAM role through IRSA |
| Owner | AWS VPC CNI |
| Kubernetes Subject | `system:serviceaccount:kube-system:aws-node` |

#### Purpose

Allows the VPC CNI to call AWS networking APIs required for pod networking.

#### Trust

The role trust is restricted to:

```text
EKS OIDC provider
aud = sts.amazonaws.com
sub = system:serviceaccount:kube-system:aws-node
```

#### Authority

The role carries the AWS networking permissions required by the CNI.

#### Authority Withheld

The CNI role is not shared with:

```text
Application pods
Jenkins
Cluster Autoscaler
AWS Load Balancer Controller
```

#### Credential Location

No static key exists.

The Kubernetes ServiceAccount receives temporary credentials through IRSA.

#### Rotation / Replacement

```text
Create replacement role
Update addon ServiceAccount role ARN
Validate networking
Remove old role
```

#### Offboarding

If the CNI identity is replaced or retired:

```text
Update/remove addon role reference
Remove trust
Remove policy attachment
Delete IAM role
```

Removing the IAM role before updating the addon could disrupt pod networking.

---

### 12. AWS Load Balancer Controller Identity

| Field | Value |
| ----- | ----- |
| Identity | `eks-kubernetes-cicd-load-balancer-controller-role` |
| Type | AWS IAM role through IRSA |
| Owner | AWS Load Balancer Controller |
| Kubernetes Subject | `system:serviceaccount:kube-system:aws-load-balancer-controller` |

#### Purpose

Allows the controller to create and manage AWS load-balancing resources from Kubernetes Ingress state.

#### Trust

Restricted through the EKS OIDC provider to the exact ServiceAccount subject.

#### Authority

The controller receives AWS permissions needed for ALB reconciliation.

#### Authority Withheld

The Flask application does not receive ALB-management authority.

The role is not attached to EKS worker nodes.

#### Credential Location

Temporary IRSA credentials.

#### Evidence

- `docs/evidence/security/load-balancer-controller-identity.png`

#### Rotation / Replacement

```text
Create replacement IAM role
Update Kubernetes ServiceAccount role annotation / Helm configuration
Validate controller
Remove old role
```

#### Offboarding

```text
Remove Ingress workloads if appropriate
Remove ServiceAccount trust
Delete policy attachment
Delete IAM role
Remove controller if no longer required
```

Deleting only the Ingress does not retire the controller identity.

---

### 13. Cluster Autoscaler Identity

| Field | Value |
| ----- | ----- |
| Identity | `eks-kubernetes-cicd-cluster-autoscaler-role` |
| Type | AWS IAM role through IRSA |
| Owner | Kubernetes Cluster Autoscaler |
| Kubernetes Subject | `system:serviceaccount:kube-system:cluster-autoscaler` |

#### Purpose

Allows Kubernetes to modify EKS worker capacity when scheduling demand changes.

#### Authority

The role can perform scaling operations such as:

```text
autoscaling:SetDesiredCapacity
autoscaling:TerminateInstanceInAutoScalingGroup
```

Scaling actions are constrained by cluster ownership tags.

Discovery APIs use wildcard scope where the AWS authorization model requires it.

#### Authority Withheld

The autoscaler cannot use its identity as an application identity.

The Flask workload cannot change Auto Scaling capacity.

#### Credential Location

Temporary IRSA credentials.

#### Evidence

- `docs/evidence/security/cluster-autoscaler-identity.png`

#### Rotation / Replacement

```text
Create replacement role
Update ServiceAccount role binding
Validate scale-out / scale-in
Remove previous role
```

#### Offboarding

```text
Disable/remove Cluster Autoscaler
Remove ServiceAccount IAM trust
Remove IAM policy
Delete role
Confirm node group desired capacity ownership returns to another controller/operator
```

The runtime owner of `desired_size` must be considered when the autoscaler is removed.

---

### 14. EKS Worker Node Role

| Field | Value |
| ----- | ----- |
| Identity | `eks-kubernetes-cicd-node-role` |
| Type | AWS IAM role attached to EC2 worker nodes |
| Owner | EKS managed node group |

#### Purpose

Allows worker nodes to participate in the EKS cluster and retrieve application images from ECR.

#### Authority

The role receives:

```text
AmazonEKSWorkerNodePolicy
AmazonEC2ContainerRegistryPullOnly
```

#### Authority Withheld

The role does not carry the VPC CNI policy.

CNI permissions are separated into the dedicated IRSA role.

This reduces the AWS authority attached to every worker node.

#### Credential Location

EC2 instance-profile temporary credentials.

#### Rotation / Replacement

Worker-role replacement usually requires a node-group rollout or replacement.

#### Offboarding

```text
Drain/remove node group
Remove role policy attachments
Delete node IAM role
```

The role should not be deleted while active nodes still depend on it.

---

## Credentialless and Low-Authority Identities

An important governance finding from this project is that not every identity requires a traditional secret.

Examples:

```text
GitHub Actions
    -> OIDC federation
    -> no AWS access key


IRSA controllers
    -> projected workload federation
    -> no AWS access key


Jenkins
    -> EC2 role
    -> no AWS access key


Application ServiceAccount
    -> no AWS role
    -> no mounted API token
```

Identity governance should inventory these identities even when no password, API key, or secret exists.

A non-human identity can have significant authority without possessing a long-lived credential.

---

## Explicit Non-Identity Decision

### Flask Application AWS Access

A deliberate decision was made not to create:

```text
IAM role for Flask application
IRSA mapping for Flask ServiceAccount
AWS access key
AWS secret
```

The application does not call AWS APIs.

Granting an AWS identity would create:

```text
Another trust relationship
Another lifecycle object
Another permission surface
Another identity to monitor
Another identity to offboard
```

with no business or technical requirement.

The decision was:

> No AWS identity is safer than a least-privileged AWS identity when the workload does not need AWS access at all.

---

## Lifecycle Governance

Non-human identity lifecycle is treated as:

```text
Discovery
    |
    v
Ownership
    |
    v
Provisioning
    |
    v
Permission assignment
    |
    v
Runtime monitoring
    |
    v
Access review
    |
    v
Rotation / modification
    |
    v
Offboarding
```

### Onboarding Principles

Before onboarding a new non-human identity, answer:

```text
What workload owns it?

What system must it authenticate to?

What exact operation requires the identity?

Can workload federation replace a static credential?

Can the permission be scoped to one resource?

Does the workload need an identity at all?

Who owns rotation?

What event triggers retirement?
```

### Access Review Questions

Periodic review of this inventory should ask:

```text
Does the workload still exist?

Does the identity still have an owner?

Is the identity still being used?

Has its permission set expanded?

Does its trust relationship still match the intended workload?

Does it retain access to resources no longer required?

Could static credentials be replaced with federation?

Could the identity be removed entirely?
```

### Offboarding Principles

Deleting a workload is not sufficient proof that its identity has been removed.

Offboarding should inspect:

```text
IAM role
IAM trust relationship
Attached IAM policies
EKS access entry
Kubernetes RoleBinding
Kubernetes ServiceAccount
OIDC subject
Git deploy key
Stored private key
Kubernetes Secret
CI/CD credential
Repository token configuration
```

The final question is:

> Can the retired workload still authenticate anywhere?

If the answer is yes, offboarding is incomplete.

---

## NHI Offboarding Examples

### Jenkins Retirement

```text
Stop Jenkins
Remove GitHub deploy key
Remove Jenkins private Git credential
Remove EKS access entry
Remove Kubernetes RoleBinding
Remove Jenkins IAM role
Remove instance profile
Terminate Jenkins EC2
Remove SSM-related configuration
```

### GitHub Actions Retirement

```text
Remove workflow
Remove OIDC IAM trust
Delete GitHub Actions IAM role
Remove attached policy
```

There are no long-lived AWS access keys to revoke.

### Argo CD Retirement

```text
Remove Argo Applications
Remove GitHub deploy key
Delete repository credential Secret
Remove Argo RBAC
Remove Argo service accounts
Uninstall Argo CD
Delete argocd namespace if unused
```

### Application Retirement

```text
Remove desired state
Delete workload resources
Delete application ServiceAccount
Verify no IAM role trusts its ServiceAccount subject
Verify no Kubernetes token or Secret remains
```

### Controller Retirement

For an IRSA-enabled controller:

```text
Remove controller workload
Remove Kubernetes ServiceAccount
Remove IAM trust
Remove IAM policy attachment
Delete IAM role
Verify no remaining workload uses the role
```

This applies to:

```text
AWS Load Balancer Controller
Cluster Autoscaler
VPC CNI role replacement
```

---

## Identity Evidence Model

Evidence should answer one or more of these claims:

```text
Identity exists
Trust is restricted
Permission is scoped
Credential is not static
Credential is not mounted
Access denial works
Workload cannot exceed intended authority
Identity has no AWS role
```

Representative evidence includes:

- `docs/evidence/security/application-serviceaccount-no-aws-role.png`
- `docs/evidence/security/application-workload-identity-controls.png`
- `docs/evidence/security/no-serviceaccount-token.png`
- `docs/evidence/security/load-balancer-controller-identity.png`
- `docs/evidence/security/cluster-autoscaler-identity.png`
- `docs/evidence/security/jenkins-kubernetes-rbac-boundary.png`
- `docs/evidence/security/ansible-execution-role-assumption.png`
- `docs/evidence/security/jenkins-ssm-managed-instance.png`
- `docs/evidence/security/cicd-git-identity-separation.png`
- `docs/evidence/gitops/github-actions-gitops-success.png`
- `docs/evidence/gitops/argocd-synced-healthy.png`

---

## Governance Findings

Several lessons emerged from the implementation.

### 1. Identity does not automatically mean authority

The application has a Kubernetes ServiceAccount but receives no AWS permissions.

An identity can exist without being broadly privileged.

### 2. Authentication and authorization are separate problems

Jenkins authenticates to EKS through AWS IAM.

Its Kubernetes permissions are still controlled independently through RBAC.

```text
IAM authentication != Kubernetes authorization
```

### 3. Wildcard syntax does not automatically mean excessive privilege

Some AWS actions do not support resource-level authorization.

For those operations:

```text
Resource: "*"
```

may be required by the AWS authorization model.

Least privilege must be evaluated through effective authority, supported resource scoping, conditions, and action selection rather than the visual absence of `*`.

### 4. Federation reduces credential lifecycle burden

GitHub Actions, IRSA controllers, Jenkins EC2, and Terraform role assumption all use temporary credentials.

This reduces the number of long-lived secrets requiring manual rotation.

It does not remove the need to govern the identity itself.

Trust policies and role permissions still require lifecycle management.

### 5. Read-only credentials can still be security-sensitive

Jenkins and Argo CD deploy keys cannot modify Git.

They can still read private source code and configuration.

Read-only machine credentials still require:

```text
Ownership
Storage controls
Rotation
Revocation
Monitoring
```

### 6. Identity offboarding is multi-layered

A Kubernetes workload may be removed while its:

```text
IAM role
OIDC trust
Git deploy key
RoleBinding
Secret
```

continues to exist.

Workload deletion and identity retirement are separate checks.

---

## Governance Summary

The project contains multiple non-human identities, but they do not share one global authority model.

```text
Terraform
    -> infrastructure provisioning


Ansible
    -> Jenkins configuration


Jenkins
    -> traditional CI/CD


GitHub Actions
    -> artifact publishing + desired-state update


Argo CD
    -> Kubernetes reconciliation


VPC CNI
    -> pod networking


Load Balancer Controller
    -> AWS ingress infrastructure


Cluster Autoscaler
    -> worker capacity


Application
    -> no AWS authority
```

Each identity has:

```text
A defined owner
A defined workload
A defined trust target
A bounded purpose
A retirement path
```

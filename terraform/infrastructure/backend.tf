terraform {
  backend "s3" {
    bucket       = "eks-kubernetes-cicd-tfstate-883d0964"
    key          = "infrastructure/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
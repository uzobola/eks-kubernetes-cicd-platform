pipeline {
    agent any

    options {
        skipDefaultCheckout(true)
        disableConcurrentBuilds()
    }

    environment {
        AWS_REGION       = 'us-east-1'
        EKS_CLUSTER_NAME = 'eks-kubernetes-cicd-cluster'
        ECR_REPOSITORY   = '421438965568.dkr.ecr.us-east-1.amazonaws.com/eks-kubernetes-cicd-app'
    }

    stages {

        stage('Checkout') {
            steps {
                checkout scm

                sh '''
                    echo "Checked out commit:"
                    git rev-parse --short HEAD
                '''
            }
        }

        stage('AWS Identity Preflight') {
            steps {
                sh '''
                    set -eu

                    echo "AWS identity used by Jenkins:"
                    aws sts get-caller-identity

                    echo "Verifying Jenkins can describe the EKS cluster:"
                    aws eks describe-cluster \
                      --region "$AWS_REGION" \
                      --name "$EKS_CLUSTER_NAME" \
                      --query 'cluster.name' \
                      --output text

                    echo "Verifying Jenkins can request an ECR authorization token:"
                    aws ecr get-login-password \
                      --region "$AWS_REGION" \
                      > /dev/null

                    echo "AWS identity preflight passed."
                '''
            }
        }


        stage('Checkov IaC Security') {
            steps {
                sh '''
                    set -eu

                    echo "Running Checkov against Terraform infrastructure..."

                    checkov \
                    --directory terraform \
                    --framework terraform \
                    --quiet \
                    --compact

                    echo "Checkov security gate passed."
                '''
                }
    }
    }
}
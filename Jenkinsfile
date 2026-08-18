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

                    echo "Running Checkov against Terraform..."

                    checkov \
                      --directory terraform \
                      --framework terraform \
                      --quiet \
                      --compact

                    echo "Checkov security gate passed."
                '''
            }
        }

        stage('Build Metadata') {
            steps {
                script {
                    env.GIT_SHORT_SHA = sh(
                        script: 'git rev-parse --short HEAD',
                        returnStdout: true
                    ).trim()

                    env.IMAGE_TAG = "${env.GIT_SHORT_SHA}-${env.BUILD_NUMBER}"
                    env.IMAGE_URI = "${env.ECR_REPOSITORY}:${env.IMAGE_TAG}"
                }

                sh '''
                    echo "Commit:     $GIT_SHORT_SHA"
                    echo "Build:      $BUILD_NUMBER"
                    echo "Image tag:  $IMAGE_TAG"
                    echo "Image URI:  $IMAGE_URI"
                '''
            }
        }

        stage('Docker Build') {
            steps {
                sh '''
                    set -eu

                    echo "Building application image..."

                    docker build \
                      --tag "$IMAGE_URI" \
                      eks-kubernetes-cicd-platform/app

                    docker image inspect "$IMAGE_URI" > /dev/null

                    echo "Docker build passed."
                '''
            }
        }

        stage('Trivy Security Gate') {
            steps {
                sh '''
                    set -eu

                    echo "Scanning image for HIGH and CRITICAL vulnerabilities..."

                    trivy image \
                      --scanners vuln \
                      --severity HIGH,CRITICAL \
                      --exit-code 1 \
                      "$IMAGE_URI"

                    echo "Trivy security gate passed."
                '''
            }
        }

        stage('ECR Push') {
            steps {
                sh '''
                    set -eu

                    ECR_REGISTRY="${ECR_REPOSITORY%%/*}"
                    ECR_REPOSITORY_NAME="${ECR_REPOSITORY##*/}"

                    echo "Authenticating Docker to ECR..."

                    aws ecr get-login-password \
                      --region "$AWS_REGION" \
                    | docker login \
                      --username AWS \
                      --password-stdin "$ECR_REGISTRY"

                    echo "Pushing immutable image:"
                    echo "$IMAGE_URI"

                    docker push "$IMAGE_URI"

                    echo "Verifying image exists in ECR..."

                    aws ecr describe-images \
                      --region "$AWS_REGION" \
                      --repository-name "$ECR_REPOSITORY_NAME" \
                      --image-ids imageTag="$IMAGE_TAG" \
                      --query 'imageDetails[0].[imageTags[0],imageDigest]' \
                      --output table

                    echo "ECR push verified."
                '''
            }
        }
    }
}
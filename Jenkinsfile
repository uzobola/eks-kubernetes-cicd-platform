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

                stage('EKS Authentication') {
            steps {
                sh '''
                    set -eu

                    mkdir -p "$WORKSPACE/.kube"
                    export KUBECONFIG="$WORKSPACE/.kube/config"

                    echo "Generating temporary EKS kubeconfig..."

                    aws eks update-kubeconfig \
                      --region "$AWS_REGION" \
                      --name "$EKS_CLUSTER_NAME" \
                      --kubeconfig "$KUBECONFIG"

                    echo "Verifying Jenkins Kubernetes authorization..."

                    kubectl auth can-i update deployments \
                      --namespace challenge-app

                    kubectl auth can-i delete nodes

                    echo "EKS authentication verified."
                '''
            }
        }

        stage('Helm Deploy') {
            steps {
                sh '''
                    set -eu
                    export KUBECONFIG="$WORKSPACE/.kube/config"

                    echo "Deploying image:"
                    echo "$IMAGE_URI"

                    helm upgrade --install challenge-app \
                      helm/challenge-app \
                      --namespace challenge-app \
                      --set image.repository="$ECR_REPOSITORY" \
                      --set image.tag="$IMAGE_TAG" \
                      --atomic \
                      --wait \
                      --timeout 5m

                    echo "Helm deployment completed."
                '''
            }
        }

        stage('Rollout Verification') {
            steps {
                sh '''
                    set -eu
                    export KUBECONFIG="$WORKSPACE/.kube/config"

                    echo "Verifying Kubernetes rollout..."

                    kubectl rollout status \
                      deployment/challenge-app \
                      --namespace challenge-app \
                      --timeout=180s

                    echo
                    echo "Deployed image:"

                    kubectl get deployment challenge-app \
                      --namespace challenge-app \
                      -o jsonpath='{.spec.template.spec.containers[0].image}'

                    echo
                    echo

                    EXPECTED_IMAGE="$IMAGE_URI"

                    ACTUAL_IMAGE=$(kubectl get deployment challenge-app \
                      --namespace challenge-app \
                      -o jsonpath='{.spec.template.spec.containers[0].image}')

                    if [ "$ACTUAL_IMAGE" != "$EXPECTED_IMAGE" ]; then
                        echo "ERROR: deployed image does not match pipeline image."
                        echo "Expected: $EXPECTED_IMAGE"
                        echo "Actual:   $ACTUAL_IMAGE"
                        exit 1
                    fi

                    echo "Rollout verification passed."
                '''
            }
        }

        stage('Live Application Test') {
            steps {
                sh '''
                    set -eu
                    export KUBECONFIG="$WORKSPACE/.kube/config"

                    ALB_HOST=$(kubectl get ingress challenge-app \
                      --namespace challenge-app \
                      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

                    if [ -z "$ALB_HOST" ]; then
                        echo "ERROR: ALB hostname not available."
                        exit 1
                    fi

                    echo "Testing live application:"
                    echo "http://$ALB_HOST"

                    ATTEMPT=1

                    while [ "$ATTEMPT" -le 12 ]; do
                        if curl --fail --silent --show-error \
                          "http://$ALB_HOST/health"; then
                            echo
                            echo "Health endpoint passed."
                            break
                        fi

                        if [ "$ATTEMPT" -eq 12 ]; then
                            echo "ERROR: live health check failed."
                            exit 1
                        fi

                        echo "Waiting for application... attempt $ATTEMPT/12"
                        ATTEMPT=$((ATTEMPT + 1))
                        sleep 10
                    done

                    echo "Validating application response..."

                    curl --fail --silent \
                      "http://$ALB_HOST/" \
                      | grep -F "Congratulations Challenge Completed !"

                    echo
                    echo "Live application test passed."
                '''
            }
        }
    }

    post {
        always {
            sh '''
                rm -rf "$WORKSPACE/.kube" || true
            '''
        }
    }
}
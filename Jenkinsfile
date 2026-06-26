pipeline {
    agent any

    environment {
        AWS_REGION       = 'ap-south-1'
        ECR_REGISTRY     = credentials('ecr-registry-url')
        ECR_REPOSITORY   = 'icounter-api'
        IMAGE_TAG        = "${env.BUILD_NUMBER}"
        EKS_CLUSTER_NAME = 'icounter-cluster'
        HELM_RELEASE     = 'icounter-api'
        K8S_NAMESPACE    = 'icounter'
    }

    parameters {
        choice(name: 'ENVIRONMENT', choices: ['staging', 'production'], description: 'Target deployment environment')
        booleanParam(name: 'SKIP_TESTS', defaultValue: false, description: 'Skip unit tests')
        booleanParam(name: 'DRY_RUN', defaultValue: false, description: 'Helm dry-run only')
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Build') {
            steps {
                dir('app') {
                    sh 'npm ci'
                }
            }
        }

        stage('Unit Test') {
            when {
                expression { !params.SKIP_TESTS }
            }
            steps {
                dir('app') {
                    sh 'npm test'
                }
            }
        }

        stage('Docker Build') {
            steps {
                sh """
                    docker build --platform linux/amd64 \
                        -t ${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG} \
                        -t ${ECR_REGISTRY}/${ECR_REPOSITORY}:latest \
                        .
                """
            }
        }

        stage('Push to ECR') {
            steps {
                sh """
                    aws ecr get-login-password --region ${AWS_REGION} \
                        | docker login --username AWS --password-stdin ${ECR_REGISTRY}
                    docker push ${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}
                    docker push ${ECR_REGISTRY}/${ECR_REPOSITORY}:latest
                """
            }
        }

        stage('Deploy to Kubernetes') {
            steps {
                sh "aws eks update-kubeconfig --name ${EKS_CLUSTER_NAME} --region ${AWS_REGION}"
                sh "kubectl create namespace ${K8S_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -"
                script {
                    def dryRunFlag = params.DRY_RUN ? '--dry-run' : ''
                    def valuesFile = "helm/icounter-api/values-${params.ENVIRONMENT}.yaml"
                    sh """
                        helm upgrade --install ${HELM_RELEASE} ./helm/icounter-api \
                            --namespace ${K8S_NAMESPACE} \
                            -f ${valuesFile} \
                            --set image.repository=${ECR_REGISTRY}/${ECR_REPOSITORY} \
                            --set image.tag=${IMAGE_TAG} \
                            --set config.appVersion=${IMAGE_TAG} \
                            --wait \
                            --timeout 300s \
                            ${dryRunFlag}
                    """
                }
            }
        }

        stage('Verify Deployment') {
            when {
                expression { !params.DRY_RUN }
            }
            steps {
                sh "kubectl rollout status deployment/${HELM_RELEASE} -n ${K8S_NAMESPACE} --timeout=120s"
                sh "kubectl get pods -n ${K8S_NAMESPACE} -l app.kubernetes.io/name=icounter-api"
                sh "kubectl get ingress -n ${K8S_NAMESPACE}"
            }
        }
    }

    post {
        failure {
            script {
                echo 'Deployment failed. Rolling back to previous revision...'
                sh "helm rollback ${HELM_RELEASE} 0 --namespace ${K8S_NAMESPACE} || true"
            }
        }
        always {
            sh "docker rmi ${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG} || true"
            cleanWs()
        }
    }
}

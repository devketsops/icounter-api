pipeline {
    agent any

    environment {
        AWS_REGION       = 'ap-south-1'
        ECR_REGISTRY     = credentials('ecr-registry-url')
        ECR_REPOSITORY   = 'icounter-api'
        EKS_CLUSTER_NAME = 'icounter-cluster'
        HELM_RELEASE     = 'icounter-api'
        K8S_NAMESPACE    = 'icounter'
    }

    options {
        timestamps()
        timeout(time: 45, unit: 'MINUTES')
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20'))
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
                script {
                    env.GIT_SHA_SHORT = sh(script: 'git rev-parse --short=7 HEAD', returnStdout: true).trim()
                    env.IMAGE_TAG = "${env.BUILD_NUMBER}-${env.GIT_SHA_SHORT}"
                }
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
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding',
                                  credentialsId: 'aws-credentials',
                                  accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                                  secretKeyVariable: 'AWS_SECRET_ACCESS_KEY']]) {
                    sh """
                        aws ecr get-login-password --region ${AWS_REGION} \
                            | docker login --username AWS --password-stdin ${ECR_REGISTRY}
                    """
                }
                sh """
                    docker build --platform linux/amd64 \
                        -t ${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG} \
                        .
                """
            }
        }

        stage('Push to ECR') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding',
                                  credentialsId: 'aws-credentials',
                                  accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                                  secretKeyVariable: 'AWS_SECRET_ACCESS_KEY']]) {
                    sh """
                        aws ecr get-login-password --region ${AWS_REGION} \
                            | docker login --username AWS --password-stdin ${ECR_REGISTRY}
                        docker push ${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}
                    """
                }
            }
        }

        stage('Security Scan') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding',
                                  credentialsId: 'aws-credentials',
                                  accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                                  secretKeyVariable: 'AWS_SECRET_ACCESS_KEY']]) {
                    sh """
                        aws ecr wait image-scan-complete \
                            --repository-name ${ECR_REPOSITORY} \
                            --image-id imageTag=${IMAGE_TAG} \
                            --region ${AWS_REGION}

                        CRITICAL=\$(aws ecr describe-image-scan-findings \
                            --repository-name ${ECR_REPOSITORY} \
                            --image-id imageTag=${IMAGE_TAG} \
                            --region ${AWS_REGION} \
                            --query 'imageScanFindings.findingSeverityCounts.CRITICAL' \
                            --output text)

                        echo "CRITICAL vulnerabilities: \${CRITICAL}"

                        if [ "\${CRITICAL}" != "None" ] && [ "\${CRITICAL}" != "0" ]; then
                            echo "Blocking deployment — \${CRITICAL} CRITICAL vulnerabilities found."
                            exit 1
                        fi
                    """
                }
            }
        }

        stage('Deploy to Kubernetes') {
            when {
                anyOf {
                    expression { params.ENVIRONMENT != 'production' }
                    expression { env.BRANCH_NAME == 'main' || env.GIT_BRANCH?.endsWith('/main') }
                }
            }
            steps {
                script {
                    if (params.ENVIRONMENT == 'production') {
                        timeout(time: 60, unit: 'MINUTES') {
                            input message: 'Deploy to PRODUCTION?',
                                  ok: 'Approve',
                                  submitter: 'admin,devops-leads'
                        }
                    }
                }
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding',
                                  credentialsId: 'aws-credentials',
                                  accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                                  secretKeyVariable: 'AWS_SECRET_ACCESS_KEY']]) {
                    sh "aws eks update-kubeconfig --name ${EKS_CLUSTER_NAME} --region ${AWS_REGION}"
                    sh "kubectl create namespace ${K8S_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -"
                    script {
                        def dryRunFlag = params.DRY_RUN ? '--dry-run=client' : ''
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
        }

        stage('Verify Deployment') {
            when {
                expression { !params.DRY_RUN }
            }
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding',
                                  credentialsId: 'aws-credentials',
                                  accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                                  secretKeyVariable: 'AWS_SECRET_ACCESS_KEY']]) {
                    sh "kubectl rollout status deployment/${HELM_RELEASE} -n ${K8S_NAMESPACE} --timeout=120s"
                    sh "kubectl get pods -n ${K8S_NAMESPACE} -l app=${HELM_RELEASE}"
                    sh "kubectl get ingress -n ${K8S_NAMESPACE}"
                    script {
                        def podName = sh(
                            script: "kubectl get pods -n ${K8S_NAMESPACE} -l app=${HELM_RELEASE} -o jsonpath='{.items[0].metadata.name}'",
                            returnStdout: true
                        ).trim()
                        sh "kubectl exec -n ${K8S_NAMESPACE} ${podName} -- wget -qO- --timeout=5 http://localhost:3000/health"
                    }
                }
            }
        }
    }

    post {
        success {
            echo "Deployment of ${env.IMAGE_TAG} to ${params.ENVIRONMENT} succeeded."
        }
        failure {
            script {
                echo "Deployment failed. Rolling back to previous revision..."
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding',
                                  credentialsId: 'aws-credentials',
                                  accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                                  secretKeyVariable: 'AWS_SECRET_ACCESS_KEY']]) {
                    sh "helm rollback ${HELM_RELEASE} 0 --namespace ${K8S_NAMESPACE} || true"
                }
            }
        }
        always {
            sh "docker rmi ${ECR_REGISTRY}/${ECR_REPOSITORY}:${env.IMAGE_TAG} || true"
            cleanWs()
        }
    }
}

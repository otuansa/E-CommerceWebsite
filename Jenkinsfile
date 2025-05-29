pipeline {
    agent any

    parameters {
        string(name: 'AWS_ACCOUNT_ID', defaultValue: '205930632952', description: 'AWS Account ID')
        string(name: 'AWS_REGION', defaultValue: 'eu-west-2', description: 'AWS Region')
        string(name: 'IMAGE_TAG', defaultValue: '', description: 'Docker image tag (leave blank to use build number and commit hash)')
        string(name: 'CLUSTER_NAME', defaultValue: 'your-eks-cluster-name', description: 'EKS Cluster Name')
    }

    stages {
        stage('Compute Image Tag') {
            steps {
                script {
                    // Declare variables with def to avoid global field issues
                    def gitCommit = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
                    def imageTag = params.IMAGE_TAG ?: "v${env.BUILD_NUMBER}-${gitCommit}"
                    env.IMAGE_TAG = imageTag // Store in env for later stages
                }
            }
        }

        stage('Validate Parameters') {
            steps {
                script {
                    if (!params.AWS_ACCOUNT_ID ==~ /\d{12}/) {
                        error "AWS_ACCOUNT_ID must be a 12-digit number"
                    }
                }
            }
        }

        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Load Dynamic Config') {
            steps {
                withAWS(credentials: 'aws-credentials-id', region: "${params.AWS_REGION}") {
                    script {
                        def awsAccountId = params.AWS_ACCOUNT_ID
                        def clusterName = params.CLUSTER_NAME
                        try {
                            awsAccountId = sh(script: "aws ssm get-parameter --name /jenkins/AWS_ACCOUNT_ID --with-decryption --query Parameter.Value --output text", returnStdout: true).trim()
                            echo "Fetched AWS_ACCOUNT_ID from SSM: ${awsAccountId}"
                        } catch (Exception e) {
                            echo "Failed to fetch AWS_ACCOUNT_ID from SSM, using parameter default: ${awsAccountId}"
                        }
                        try {
                            clusterName = sh(script: "aws ssm get-parameter --name /jenkins/CLUSTER_NAME --with-decryption --query Parameter.Value --output text", returnStdout: true).trim()
                            echo "Fetched CLUSTER_NAME from SSM: ${clusterName}"
                        } catch (Exception e) {
                            echo "Failed to fetch CLUSTER_NAME from SSM, using parameter default: ${clusterName}"
                        }
                        def dockerImage = "${awsAccountId}.dkr.ecr.${params.AWS_REGION}.amazonaws.com/projectme-ak:${env.IMAGE_TAG}"
                        env.DOCKER_IMAGE = dockerImage // Store in env for later stages
                    }
                }
            }
        }

        stage('Ensure ECR Repository') {
            steps {
                withAWS(credentials: 'aws-credentials-id', region: "${params.AWS_REGION}") {
                    script {
                        sh "aws ecr describe-repositories --repository-names projectme-ak --region ${params.AWS_REGION} || aws ecr create-repository --repository-name projectme-ak --region ${params.AWS_REGION}"
                    }
                }
            }
        }

        stage('Build Docker Image') {
            steps {
                script {
                    def dockerImage = docker.build("${env.DOCKER_IMAGE}", '-f webapp/Dockerfile ./webapp')
                }
            }
        }

        stage('Test Docker Image') {
            steps {
                script {
                    def container = docker.image("${env.DOCKER_IMAGE}").run('-p 8080:80')
                    sh 'sleep 5 && curl http://localhost:8080'
                    container.stop()
                }
            }
        }

        stage('Login to Amazon ECR') {
            steps {
                withAWS(credentials: 'aws-credentials-id', region: "${params.AWS_REGION}") {
                    sh "aws ecr get-login-password --region ${params.AWS_REGION} | docker login --username AWS --password-stdin ${env.DOCKER_IMAGE.split(':')[0]}"
                }
            }
        }

        stage('Push Docker Image to ECR') {
            steps {
                script {
                    docker.withRegistry("https://${env.DOCKER_IMAGE.split(':')[0]}") {
                        docker.image("${env.DOCKER_IMAGE}").push()
                    }
                }
            }
        }

        stage('Update Terraform with New Image URI') {
            steps {
                script {
                    writeFile file: 'TerraformDep/terraform.tfvars', text: """
                    ecr_image_uri = "${env.DOCKER_IMAGE}"
                    cluster_name = "${env.CLUSTER_NAME}"
                    region = "${params.AWS_REGION}"
                    """
                }
            }
        }

        stage('Apply Terraform Changes') {
            steps {
                dir('TerraformDep') {
                    withAWS(credentials: 'aws-credentials-id', region: "${params.AWS_REGION}") {
                        script {
                            sh 'terraform init'
                            sh 'terraform workspace select dev || terraform workspace new dev'
                            sh 'terraform plan -out=tfplan'
                            sh 'terraform apply -auto-approve tfplan'
                        }
                    }
                }
            }
        }
    }

    post {
        always {
            sh 'docker system prune -f || true'
        }
        success {
            echo 'Pipeline completed successfully.'
        }
        failure {
            echo 'Pipeline failed.'
            dir('TerraformDep') {
                sh 'terraform init && terraform destroy -auto-approve || true'
            }
        }
    }
}
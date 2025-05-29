pipeline {
    agent any

    parameters {
        string(name: 'AWS_ACCOUNT_ID', defaultValue: '205930632952', description: 'AWS Account ID')
        string(name: 'AWS_REGION', defaultValue: 'eu-west-2', description: 'AWS Region')
        string(name: 'IMAGE_TAG', defaultValue: '', description: 'Docker image tag (leave blank to use build number and commit hash)')
        string(name: 'CLUSTER_NAME', defaultValue: 'your-eks-cluster-name', description: 'EKS Cluster Name')
        string(name: 'TEST_PORT', defaultValue: '8080', description: 'Host port for testing Docker image (use 0 for random port)')
        booleanParam(name: 'DESTROY', defaultValue: false, description: 'Check to destroy resources instead of deploying')
    }

    stages {
        stage('Compute Image Tag') {
            when {
                expression { !params.DESTROY }
            }
            steps {
                script {
                    def gitCommit = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
                    def imageTag = params.IMAGE_TAG ?: "v${env.BUILD_NUMBER}-${gitCommit}"
                    env.IMAGE_TAG = imageTag
                }
            }
        }

        stage('Validate Parameters') {
            when {
                expression { !params.DESTROY }
            }
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
            when {
                expression { !params.DESTROY }
            }
            steps {
                script {
                    def awsAccountId = params.AWS_ACCOUNT_ID
                    def clusterName = params.CLUSTER_NAME
                    try {
                        withAWS(credentials: 'access-key', region: "${params.AWS_REGION}") {
                            try {
                                awsAccountId = sh(script: "aws ssm get-parameter --name /jenkins/AWS_ACCOUNT_ID --with-decryption --query Parameter.Value --output text", returnStdout: true).trim()
                                echo "Fetched AWS_ACCOUNT_ID from SSM: ${awsAccountId}"
                            } catch (Exception e) {
                                echo "Failed to fetch AWS_ACCOUNT_ID from SSM: ${e.message}. Using default: ${awsAccountId}"
                            }
                            try {
                                clusterName = sh(script: "aws ssm get-parameter --name /jenkins/CLUSTER_NAME --with-decryption --query Parameter.Value --output text", returnStdout: true).trim()
                                echo "Fetched CLUSTER_NAME from SSM: ${clusterName}"
                            } catch (Exception e) {
                                echo "Failed to fetch CLUSTER_NAME from SSM: ${e.message}. Using default: ${clusterName}"
                            }
                        }
                    } catch (Exception e) {
                        echo "AWS credentials issue: ${e.message}. Using default parameters."
                    }
                    env.AWS_ACCOUNT_ID = awsAccountId
                    env.CLUSTER_NAME = clusterName
                    env.DOCKER_IMAGE = "${awsAccountId}.dkr.ecr.${params.AWS_REGION}.amazonaws.com/projectme-ak:${env.IMAGE_TAG}"
                }
            }
        }

        stage('Ensure ECR Repository') {
            when {
                expression { !params.DESTROY }
            }
            steps {
                script {
                    try {
                        withAWS(credentials: 'access-key', region: "${params.AWS_REGION}") {
                            sh "aws ecr describe-repositories --repository-names projectme-ak --region ${params.AWS_REGION} || aws ecr create-repository --repository-name projectme-ak --region ${params.AWS_REGION}"
                        }
                    } catch (Exception e) {
                        echo "Failed to ensure ECR repository: ${e.message}. Assuming repository exists."
                    }
                }
            }
        }

        stage('Build Docker Image') {
            when {
                expression { !params.DESTROY }
            }
            steps {
                script {
                    docker.build("${env.DOCKER_IMAGE}", '-f webapp/Dockerfile ./webapp')
                }
            }
        }

        stage('Test Docker Image') {
            when {
                expression { !params.DESTROY }
            }
            steps {
                script {
                    def testPort = params.TEST_PORT.toInteger()
                    def hostPort = testPort == 0 ? '' : "-p ${testPort}:80"
                    def containerName = "test-container-${env.BUILD_NUMBER}"
                    try {
                        sh "docker run -d ${hostPort} --name ${containerName} ${env.DOCKER_IMAGE}"
                        sh "sleep 5 && curl http://localhost:${testPort == 0 ? '80' : testPort}"
                    } finally {
                        sh "docker stop ${containerName} || true"
                        sh "docker rm ${containerName} || true"
                    }
                }
            }
        }

        stage('Login to Amazon ECR') {
            when {
                expression { !params.DESTROY }
            }
            steps {
                script {
                    withAWS(credentials: 'access-key', region: "${params.AWS_REGION}") {
                        sh "aws ecr get-login-password --region ${params.AWS_REGION} | docker login --username AWS --password-stdin ${env.DOCKER_IMAGE.split(':')[0]}"
                    }
                }
            }
        }

        stage('Push Docker Image to ECR') {
            when {
                expression { !params.DESTROY }
            }
            steps {
                script {
                    docker.withRegistry("https://${env.DOCKER_IMAGE.split(':')[0]}") {
                        docker.image("${env.DOCKER_IMAGE}").push()
                    }
                }
            }
        }

        stage('Update Terraform with New Image URI') {
            when {
                expression { !params.DESTROY }
            }
            steps {
                script {
                    writeFile file: 'TerraformDep/terraform.tfvars', text: """
                    ecr_image_uri = "${env.DOCKER_IMAGE}"
                    cluster_name = "${env.CLUSTER_NAME}"
                    region = "${params.AWS_REGION}"
                    service_type = "LoadBalancer"
                    aws_account_id = "${env.AWS_ACCOUNT_ID}"
                    """
                }
            }
        }

        stage('Apply Terraform Changes') {
            when {
                expression { !params.DESTROY }
            }
            steps {
                dir('TerraformDep') {
                    script {
                        withAWS(credentials: 'access-key', region: "${params.AWS_REGION}") {
                            sh 'terraform init'
                            sh 'terraform workspace select dev || terraform workspace new dev'
                            sh 'terraform plan -out=tfplan'
                            sh 'terraform apply -auto-approve tfplan'
                        }
                    }
                }
            }
        }

        stage('Terraform Destroy') {
            when {
                expression { params.DESTROY }
            }
            steps {
                dir('TerraformDep') {
                    script {
                        withAWS(credentials: 'access-key', region: "${params.AWS_REGION}") {
                            sh 'terraform init'
                            sh 'terraform workspace select dev || true'
                            sh 'terraform destroy -auto-approve'
                        }
                    }
                }
            }
        }
    }

    post {
        always {
            script {
                if (!params.DESTROY) {
                    sh 'docker system prune -f || true'
                    sh 'docker ps -q --filter "name=test-container-${env.BUILD_NUMBER}" | xargs -r docker stop || true'
                    sh 'docker ps -a -q --filter "name=test-container-${env.BUILD_NUMBER}" | xargs -r docker rm || true'
                }
                echo 'Cleaning up workspace.'
                cleanWs()
            }
        }
        success {
            echo params.DESTROY ? 'Terraform destroy completed successfully.' : 'Pipeline completed successfully.'
        }
        failure {
            echo params.DESTROY ? 'Terraform destroy failed.' : 'Pipeline failed.'
            script {
                if (!params.DESTROY) {
                    dir('TerraformDep') {
                        sh 'terraform init && terraform destroy -auto-approve || true'
                    }
                }
            }
        }
    }
}
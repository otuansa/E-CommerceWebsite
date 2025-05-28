pipeline {
    agent { label 'docker-terraform-agent' }

    parameters {
        string(name: 'AWS_ACCOUNT_ID', defaultValue: '205930632952', description: 'AWS Account ID')
        string(name: 'AWS_REGION', defaultValue: 'eu-west-2', description: 'AWS Region')
        string(name: 'IMAGE_TAG', defaultValue: "v${env.BUILD_NUMBER}-${sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()}", description: 'Docker image tag')
        string(name: 'CLUSTER_NAME', defaultValue: 'your-eks-cluster-name', description: 'EKS Cluster Name')
    }

    stages {
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
                        try {
                            AWS_ACCOUNT_ID = sh(script: "aws ssm get-parameter --name /jenkins/AWS_ACCOUNT_ID --with-decryption --query 'Parameter.Value' --output text", returnStdout: true).trim()
                        } catch (Exception e) {
                            AWS_ACCOUNT_ID = params.AWS_ACCOUNT_ID
                        }
                        try {
                            CLUSTER_NAME = sh(script: "aws ssm get-parameter --name /jenkins/CLUSTER_NAME --with-decryption --query 'Parameter.Value' --output text", returnStdout: true).trim()
                        } catch (Exception e) {
                            CLUSTER_NAME = params.CLUSTER_NAME
                        }
                        DOCKER_IMAGE = "${AWS_ACCOUNT_ID}.dkr.ecr.${params.AWS_REGION}.amazonaws.com/projectme-ak:${params.IMAGE_TAG}"
                    }
                }
            }
        }

        stage('Build Docker Image') {
            steps {
                script {
                    docker.build(DOCKER_IMAGE, '-f webapp/Dockerfile ./webapp')
                }
            }
        }

        stage('Test Docker Image') {
            steps {
                script {
                    def container = docker.image(DOCKER_IMAGE).run('-p 8080:80')
                    sh 'sleep 5 && curl http://localhost:8080'
                    container.stop()
                }
            }
        }

        stage('Login to Amazon ECR') {
            steps {
                withAWS(credentials: 'aws-credentials-id', region: "${params.AWS_REGION}") {
                    sh "aws ecr get-login-password --region ${params.AWS_REGION} | docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${params.AWS_REGION}.amazonaws.com"
                }
            }
        }

        stage('Push Docker Image to ECR') {
            steps {
                script {
                    docker.withRegistry("https://${AWS_ACCOUNT_ID}.dkr.ecr.${params.AWS_REGION}.amazonaws.com") {
                        docker.image(DOCKER_IMAGE).push()
                    }
                }
            }
        }

        stage('Update Terraform with New Image URI') {
            steps {
                script {
                    writeFile file: 'TerraformDep/terraform.tfvars', text: """
                    ecr_image_uri = "${DOCKER_IMAGE}"
                    cluster_name = "${CLUSTER_NAME}"
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
            sh 'docker system prune -f'
        }
        success {
            echo 'Pipeline completed successfully.'
        }
        failure {
            echo 'Pipeline failed.'
            dir('TerraformDep') {
                sh 'terraform destroy -auto-approve || true'
            }
        }
    }
}
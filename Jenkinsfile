pipeline {
    agent any

    environment {
        // Default values (can be overridden by parameters or external config)
        AWS_REGION = 'eu-west-2'
        ECR_REPOSITORY = 'projectme-ak'
    }

    parameters {
        string(name: 'AWS_ACCOUNT_ID', defaultValue: '205930632952', description: 'AWS Account ID')
        string(name: 'IMAGE_TAG', defaultValue: "${env.BUILD_NUMBER}", description: 'Docker image tag')
        string(name: 'CLUSTER_NAME', defaultValue: 'your-eks-cluster-name', description: 'EKS Cluster Name')
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Load Dynamic Config') {
            steps {
                script {
                    // Fetch dynamic configuration from AWS Systems Manager Parameter Store or Secrets Manager
                    AWS_ACCOUNT_ID = sh(script: "aws ssm get-parameter --name /jenkins/AWS_ACCOUNT_ID --query 'Parameter.Value' --output text", returnStdout: true).trim()
                    AWS_REGION = sh(script: "aws ssm get-parameter --name /jenkins/AWS_REGION --query 'Parameter.Value' --output text", returnStdout: true).trim()
                    CLUSTER_NAME = sh(script: "aws ssm get-parameter --name /jenkins/CLUSTER_NAME --query 'Parameter.Value' --output text", returnStdout: true).trim()

                    // Set the Docker image URI dynamically
                    DOCKER_IMAGE = "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY}:${params.IMAGE_TAG}"
                }
            }
        }

        stage('Build Docker Image') {
            steps {
                script {
                    docker.build(DOCKER_IMAGE, './webapp')
                }
            }
        }

        stage('Login to Amazon ECR') {
            steps {
                script {
                    sh "aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
                }
            }
        }

        stage('Push Docker Image to ECR') {
            steps {
                script {
                    docker.withRegistry("https://${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com") {
                        docker.image(DOCKER_IMAGE).push()
                    }
                }
            }
        }

        stage('Update Terraform with New Image URI') {
            steps {
                script {
                    // Update the image URI in Terraform configuration
                    sh "sed -i 's|image = .*|image = \"${DOCKER_IMAGE}\"|g' TerraformDep/main.tf"

                    // Update the cluster name in Terraform configuration (if needed)
                    sh "sed -i 's|cluster_name = .*|cluster_name = \"${CLUSTER_NAME}\"|g' TerraformDep/main.tf"
                }
            }
        }

        stage('Apply Terraform Changes') {
            steps {
                dir('TerraformDep') {
                    script {
                        sh 'terraform init'
                        sh 'terraform apply -auto-approve'
                    }
                }
            }
        }
    }

    post {
        success {
            echo 'Pipeline completed successfully.'
        }
        failure {
            echo 'Pipeline failed.'
        }
    }
}
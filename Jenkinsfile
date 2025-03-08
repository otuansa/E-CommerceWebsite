pipeline {
    agent any
    
    environment {
        AWS_REGION = 'us-west-2'
        ECR_REPOSITORY = 'ecommerce-webapp'
        TERRAFORM_DIR = "${WORKSPACE}/TerraformDeployment"
        WEBAPP_DIR = "${WORKSPACE}/webapp"
        IMAGE_TAG = "v${BUILD_NUMBER}-${GIT_COMMIT.substring(0,7)}"
        ECR_URL = "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
        FULL_IMAGE_URL = "${ECR_URL}/${ECR_REPOSITORY}:${IMAGE_TAG}"
        AWS_CREDS = credentials('aws-credentials')
        TFVARS_FILE = "${TERRAFORM_DIR}/terraform.tfvars"
    }
    
    stages {
        stage('Initialize') {
            steps {
                echo "Starting pipeline for E-Commerce Website deployment"
                sh 'aws --version'
                sh 'docker --version'
                sh 'terraform --version'
                
                // Set up AWS credentials
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', 
                                  credentialsId: 'aws-credentials', 
                                  accessKeyVariable: 'AWS_ACCESS_KEY_ID', 
                                  secretKeyVariable: 'AWS_SECRET_ACCESS_KEY']]) {
                    sh '''
                        export AWS_DEFAULT_REGION=${AWS_REGION}
                        
                        # Login to ECR
                        aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_URL}
                        
                        # Ensure ECR repository exists
                        aws ecr describe-repositories --repository-names ${ECR_REPOSITORY} || \
                        aws ecr create-repository --repository-name ${ECR_REPOSITORY}
                    '''
                }
            }
        }
        
        stage('Detect Changes') {
            steps {
                script {
                    // Get the list of changed files from the webhook payload
                    def changeSet = currentBuild.changeSets
                    def webappChanged = false
                    def terraformChanged = false
                    
                    echo "Analyzing changes that triggered this build..."
                    
                    // If we don't have changesets (e.g., manual build), check git directly
                    if (changeSet.isEmpty()) {
                        echo "No changeset found, using git diff to detect changes"
                        // Get the changes between last successful build and current
                        def lastSuccessfulCommit = ""
                        if (currentBuild.previousSuccessfulBuild) {
                            lastSuccessfulCommit = sh(
                                script: "git rev-parse ${currentBuild.previousSuccessfulBuild.rawBuild.getCause(hudson.model.Cause$UpstreamCause).upstreamRun.getDisplayName()}^{commit} || git rev-parse HEAD~1", 
                                returnStdout: true
                            ).trim()
                        }
                        
                        def changes = sh(
                            script: "git diff --name-only ${lastSuccessfulCommit} HEAD || git diff --name-only HEAD~1 HEAD", 
                            returnStdout: true
                        ).trim()
                        
                        echo "Changes detected: ${changes}"
                        webappChanged = changes.contains('webapp/')
                        terraformChanged = changes.contains('TerraformDeployment/')
                    } else {
                        for (changeLogEntry in changeSet) {
                            for (affectedFile in changeLogEntry.affectedFiles) {
                                def filePath = affectedFile.path
                                echo "Changed file: ${filePath}"
                                if (filePath.startsWith('webapp/')) {
                                    webappChanged = true
                                }
                                if (filePath.startsWith('TerraformDeployment/')) {
                                    terraformChanged = true
                                }
                            }
                        }
                    }
                    
                    env.WEBAPP_CHANGED = webappChanged.toString()
                    env.TERRAFORM_CHANGED = terraformChanged.toString()
                    
                    echo "Webapp changes detected: ${env.WEBAPP_CHANGED}"
                    echo "Terraform changes detected: ${env.TERRAFORM_CHANGED}"
                }
            }
        }
        
        stage('Build & Push Docker Image') {
            when {
                expression { return env.WEBAPP_CHANGED == 'true' }
            }
            steps {
                dir("${WEBAPP_DIR}") {
                    echo "Building Docker image from ${WEBAPP_DIR}"
                    
                    withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', 
                                    credentialsId: 'aws-credentials', 
                                    accessKeyVariable: 'AWS_ACCESS_KEY_ID', 
                                    secretKeyVariable: 'AWS_SECRET_ACCESS_KEY']]) {
                        sh """
                            # Build Docker image
                            docker build -t ${FULL_IMAGE_URL} .
                            
                            # Push to ECR
                            docker push ${FULL_IMAGE_URL}
                            
                            # Store the image URL for Terraform
                            echo "${FULL_IMAGE_URL}" > ${WORKSPACE}/image_url.txt
                        """
                    }
                }
            }
        }
        
        stage('Update Terraform Variables') {
            steps {
                script {
                    echo "Updating Terraform variables for deployment"
                    
                    def imageUrl = ""
                    
                    if (env.WEBAPP_CHANGED == 'true') {
                        // Get the newly built image URL
                        imageUrl = readFile("${WORKSPACE}/image_url.txt").trim()
                        echo "New image built: ${imageUrl}"
                    } else {
                        // Get the current image URL from Terraform state if available
                        echo "Attempting to retrieve current image from Terraform state"
                        try {
                            withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', 
                                            credentialsId: 'aws-credentials', 
                                            accessKeyVariable: 'AWS_ACCESS_KEY_ID', 
                                            secretKeyVariable: 'AWS_SECRET_ACCESS_KEY']]) {
                                def currentImage = sh(
                                    script: """
                                        cd ${TERRAFORM_DIR}
                                        terraform output -raw deployed_image 2>/dev/null || echo ""
                                    """,
                                    returnStdout: true
                                ).trim()
                                
                                if (currentImage) {
                                    imageUrl = currentImage
                                    echo "Current image from Terraform state: ${imageUrl}"
                                } else {
                                    // If we can't get it from terraform output, try the tfvars file
                                    if (fileExists("${TFVARS_FILE}")) {
                                        def tfvarsContent = readFile("${TFVARS_FILE}")
                                        def matcher = tfvarsContent =~ /ecr_image_uri\s*=\s*"([^"]+)"/
                                        if (matcher.find()) {
                                            imageUrl = matcher.group(1)
                                            echo "Current image from tfvars: ${imageUrl}"
                                        }
                                    }
                                }
                            }
                        } catch (Exception e) {
                            echo "Warning: Could not retrieve current image: ${e.message}"
                        }
                        
                        // If we still don't have an image URL, we'll need to build one
                        if (!imageUrl) {
                            echo "No existing image found, will need to build a new one"
                            dir("${WEBAPP_DIR}") {
                                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', 
                                                credentialsId: 'aws-credentials', 
                                                accessKeyVariable: 'AWS_ACCESS_KEY_ID', 
                                                secretKeyVariable: 'AWS_SECRET_ACCESS_KEY']]) {
                                    sh """
                                        # Build Docker image
                                        docker build -t ${FULL_IMAGE_URL} .
                                        
                                        # Push to ECR
                                        docker push ${FULL_IMAGE_URL}
                                    """
                                }
                            }
                            imageUrl = FULL_IMAGE_URL
                            echo "Built fallback image: ${imageUrl}"
                        }
                    }
                    
                    // Update or create the terraform.tfvars file
                    sh """
                        # Make sure the terraform directory exists
                        mkdir -p ${TERRAFORM_DIR}
                        
                        # Create tfvars if it doesn't exist
                        if [ ! -f "${TFVARS_FILE}" ]; then
                            echo 'region = "${AWS_REGION}"' > ${TFVARS_FILE}
                            echo 'cluster_name = "ecommerce-eks-cluster"' >> ${TFVARS_FILE}
                            echo 'vpc_cidr = "10.0.0.0/16"' >> ${TFVARS_FILE}
                            echo 'kubernetes_version = "1.29"' >> ${TFVARS_FILE}
                        fi
                        
                        # Update the ECR image URI
                        if grep -q "ecr_image_uri" "${TFVARS_FILE}"; then
                            # Replace existing value
                            sed -i "s|ecr_image_uri = \\".*\\"|ecr_image_uri = \\"${imageUrl}\\"|g" ${TFVARS_FILE}
                        else
                            # Add new value
                            echo 'ecr_image_uri = "${imageUrl}"' >> ${TFVARS_FILE}
                        fi
                        
                        cat ${TFVARS_FILE}
                    """
                }
            }
        }
        
        stage('Terraform Plan') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', 
                                credentialsId: 'aws-credentials', 
                                accessKeyVariable: 'AWS_ACCESS_KEY_ID', 
                                secretKeyVariable: 'AWS_SECRET_ACCESS_KEY']]) {
                    dir("${TERRAFORM_DIR}") {
                        sh '''
                            export AWS_DEFAULT_REGION=${AWS_REGION}
                            terraform init -input=false
                            terraform validate
                            terraform plan -var-file=terraform.tfvars -out=tfplan
                        '''
                    }
                }
            }
        }
        
        stage('Approval') {
            when {
                anyOf {
                    expression { return env.TERRAFORM_CHANGED == 'true' }
                    expression { return env.WEBAPP_CHANGED == 'true' }
                }
            }
            steps {
                timeout(time: 1, unit: 'HOURS') {
                    input message: 'Review Terraform plan and approve deployment', ok: 'Deploy'
                }
            }
        }
        
        stage('Terraform Apply') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', 
                                credentialsId: 'aws-credentials', 
                                accessKeyVariable: 'AWS_ACCESS_KEY_ID', 
                                secretKeyVariable: 'AWS_SECRET_ACCESS_KEY']]) {
                    dir("${TERRAFORM_DIR}") {
                        sh '''
                            export AWS_DEFAULT_REGION=${AWS_REGION}
                            terraform apply -auto-approve tfplan
                        '''
                    }
                }
            }
        }
        
        stage('Verify Deployment') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', 
                                credentialsId: 'aws-credentials', 
                                accessKeyVariable: 'AWS_ACCESS_KEY_ID', 
                                secretKeyVariable: 'AWS_SECRET_ACCESS_KEY']]) {
                    script {
                        // Get Load Balancer URL from Terraform output
                        def lbUrl = sh(
                            script: """
                                cd ${TERRAFORM_DIR}
                                terraform output -raw lb_url || echo 'URL not available'
                            """,
                            returnStdout: true
                        ).trim()
                        
                        // Test the endpoint with retries
                        if (lbUrl != 'URL not available') {
                            def healthCheckAttempts = 0
                            def maxAttempts = 20
                            def isHealthy = false
                            
                            echo "Testing application at: ${lbUrl}"
                            
                            while (healthCheckAttempts < maxAttempts && !isHealthy) {
                                try {
                                    def response = sh(
                                        script: "curl -s -o /dev/null -w '%{http_code}' ${lbUrl} || echo '000'",
                                        returnStdout: true
                                    ).trim()
                                    
                                    if (response == '200') {
                                        isHealthy = true
                                        echo "✅ Deployment verified successfully! Application is accessible at: ${lbUrl}"
                                    } else {
                                        healthCheckAttempts++
                                        echo "Health check attempt ${healthCheckAttempts}/${maxAttempts}, received status ${response}. Waiting 15 seconds before retry..."
                                        sleep(15)
                                    }
                                } catch (Exception e) {
                                    healthCheckAttempts++
                                    echo "Error during health check: ${e.message}. Waiting 15 seconds before retry..."
                                    sleep(15)
                                }
                            }
                            
                            if (!isHealthy) {
                                echo "⚠️ Warning: Application health check failed after ${maxAttempts} attempts. Manual verification required."
                                echo "Load balancer URL: ${lbUrl}"
                            }
                        } else {
                            echo "⚠️ Load balancer URL not available yet. Manual verification required."
                        }
                    }
                }
            }
        }
    }
    
    post {
        success {
            echo """
            ✅ Pipeline completed successfully!
            
            Summary:
            - Web Application changes: ${env.WEBAPP_CHANGED}
            - Terraform changes: ${env.TERRAFORM_CHANGED}
            - Image tag: ${IMAGE_TAG}
            
            The E-Commerce website has been successfully deployed to AWS EKS.
            """
        }
        failure {
            echo """
            ❌ Pipeline failed!
            
            Please check the logs for details on what went wrong.
            
            Summary:
            - Web Application changes: ${env.WEBAPP_CHANGED}
            - Terraform changes: ${env.TERRAFORM_CHANGED}
            """
        }
        always {
            // Clean up Docker images
            sh "docker rmi ${FULL_IMAGE_URL} || true"
            
            // Archive terraform plan
            archiveArtifacts artifacts: 'TerraformDeployment/tfplan', allowEmptyArchive: true
            
            // Clean workspace
            cleanWs()
        }
    }
}
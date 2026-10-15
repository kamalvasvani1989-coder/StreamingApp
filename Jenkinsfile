// StreamingApp CI pipeline
// Builds the 5 service images and pushes them to Amazon ECR (ap-southeast-2).
// Auth to AWS comes from the EC2 instance role (streamingapp-jenkins-role); no keys stored in Jenkins.

pipeline {
  agent any

  options {
    timestamps()
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '15'))
    timeout(time: 30, unit: 'MINUTES')
  }

  // Fired by the GitHub webhook on every push
  triggers {
    githubPush()
  }

  environment {
    AWS_REGION    = 'ap-southeast-2'
    ECR_NAMESPACE = 'streamingapp'
  }

  stages {
    stage('Prepare') {
      steps {
        script {
          env.AWS_ACCOUNT_ID = sh(script: 'aws sts get-caller-identity --query Account --output text', returnStdout: true).trim()
          env.ECR_REGISTRY   = "${env.AWS_ACCOUNT_ID}.dkr.ecr.${env.AWS_REGION}.amazonaws.com"
          env.IMAGE_TAG      = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
        }
        echo "Commit ${env.IMAGE_TAG} -> ${env.ECR_REGISTRY}/${env.ECR_NAMESPACE}/*"
      }
    }

    stage('ECR Login') {
      steps {
        sh 'aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"'
      }
    }

    stage('Build & Push') {
      steps {
        script {
          def services = [
            auth     : 'backend/authService',
            streaming: 'backend/streamingService',
            admin    : 'backend/adminService',
            chat     : 'backend/chatService',
            frontend : 'frontend'
          ]
          def branches = [:]
          services.each { name, path ->
            branches[name] = {
              def image = "${env.ECR_REGISTRY}/${env.ECR_NAMESPACE}/${name}"
              sh """
                docker build --provenance=false -t ${image}:${env.IMAGE_TAG} -t ${image}:latest ${path}
                docker push ${image}:${env.IMAGE_TAG}
                docker push ${image}:latest
              """
            }
          }
          parallel branches
        }
      }
    }
  }

  post {
    success {
      echo "SUCCESS: all 5 images pushed with tag ${env.IMAGE_TAG}"
    }
    failure {
      echo "FAILURE: check the stage logs above"
    }
    always {
      sh 'docker image prune -f || true'
      sh 'docker logout "$ECR_REGISTRY" || true'
    }
  }
}

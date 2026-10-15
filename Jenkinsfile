// StreamingApp CI/CD pipeline
// Builds the 5 service images, pushes them to Amazon ECR (ap-southeast-2),
// deploys them to EKS with Helm, smoke-tests the live site and notifies via SNS.
// Auth to AWS comes from the EC2 instance role (streamingapp-jenkins-role); no keys stored in Jenkins.
// Kubernetes access comes from the same role via the EKS cluster's access entry.
// Put [skip ci] in a commit message (e.g. docs-only changes) to skip build and deploy.

def notify(String status) {
  def msg = """StreamingApp CI/CD: ${status}

Job:      ${env.JOB_NAME} #${env.BUILD_NUMBER}
Commit:   ${env.IMAGE_TAG ?: 'n/a'} - ${env.COMMIT_MSG ?: ''}
Duration: ${currentBuild.durationString.replace(' and counting', '')}
Build:    ${env.BUILD_URL}
App:      ${env.APP_URL}
"""
  writeFile file: 'sns-message.txt', text: msg
  sh """
    aws sns publish --region "\$AWS_REGION" --topic-arn "\$SNS_TOPIC_ARN" \\
      --subject "[Jenkins] streamingapp-ci #${env.BUILD_NUMBER} ${status}" \\
      --message file://sns-message.txt > /dev/null || echo 'WARN: SNS publish failed'
  """
}

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
    EKS_CLUSTER   = 'streamingapp-eks'
    K8S_NAMESPACE = 'streamingapp'
    HELM_RELEASE  = 'streamingapp'
    HELM_CHART    = 'helm/streamingapp'
    SNS_TOPIC_ARN = 'arn:aws:sns:ap-southeast-2:926375049914:streamingapp-alerts'
    APP_URL       = 'https://streamapp.kamalvasvani.com'
  }

  stages {
    stage('Prepare') {
      steps {
        script {
          env.AWS_ACCOUNT_ID = sh(script: 'aws sts get-caller-identity --query Account --output text', returnStdout: true).trim()
          env.ECR_REGISTRY   = "${env.AWS_ACCOUNT_ID}.dkr.ecr.${env.AWS_REGION}.amazonaws.com"
          env.IMAGE_TAG      = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
          env.COMMIT_MSG     = sh(script: 'git log -1 --pretty=%s', returnStdout: true).trim()
          env.SKIP_CI        = env.COMMIT_MSG.contains('[skip ci]') ? 'true' : 'false'
        }
        echo "Commit ${env.IMAGE_TAG} (${env.COMMIT_MSG}) -> ${env.ECR_REGISTRY}/${env.ECR_NAMESPACE}/*  skip=${env.SKIP_CI}"
      }
    }

    stage('ECR Login') {
      when { expression { env.SKIP_CI != 'true' } }
      steps {
        sh 'aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"'
      }
    }

    stage('Build & Push') {
      when { expression { env.SKIP_CI != 'true' } }
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

    stage('Deploy to EKS') {
      when { expression { env.SKIP_CI != 'true' } }
      steps {
        // Chart defaults from git + only the image tag overridden, matching the original install.
        // --atomic waits for all rollouts and automatically rolls back if any fail.
        sh '''
          aws eks update-kubeconfig --name "$EKS_CLUSTER" --region "$AWS_REGION" > /dev/null
          helm upgrade "$HELM_RELEASE" "$HELM_CHART" -n "$K8S_NAMESPACE" \
            --set image.tag="$IMAGE_TAG" --atomic --timeout 5m
          kubectl -n "$K8S_NAMESPACE" get deploy \
            -o 'custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,IMAGE:.spec.template.spec.containers[0].image'
          helm history "$HELM_RELEASE" -n "$K8S_NAMESPACE" --max 3
        '''
      }
    }

    stage('Smoke Test') {
      when { expression { env.SKIP_CI != 'true' } }
      steps {
        sh '''
          for p in /healthz /api/streaming/videos; do
            code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$APP_URL$p")
            echo "$APP_URL$p -> $code"
            [ "$code" = "200" ] || exit 1
          done
        '''
      }
    }
  }

  post {
    success {
      script {
        if (env.SKIP_CI == 'true') {
          echo "SKIPPED: [skip ci] in commit message"
          notify('SKIPPED')
        } else {
          echo "SUCCESS: ${env.IMAGE_TAG} built, pushed, deployed to EKS and smoke-tested"
          notify('SUCCESS')
        }
      }
    }
    failure {
      echo "FAILURE: check the stage logs above"
      notify('FAILED')
    }
    always {
      sh 'docker image prune -f || true'
      sh 'docker logout "$ECR_REGISTRY" || true'
    }
  }
}

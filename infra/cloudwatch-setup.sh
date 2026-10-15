#!/usr/bin/env bash
# CloudWatch Container Insights, log retention, SNS topic and alarms for StreamingApp on EKS.
# Idempotent: safe to re-run. Needs CloudWatch/SNS/EKS/ELB permissions (run as an admin profile).
# Usage: ALERT_EMAIL=you@example.com ./infra/cloudwatch-setup.sh
set -euo pipefail

R=ap-southeast-2
C=streamingapp-eks
NS=streamingapp
ALERT_EMAIL=${ALERT_EMAIL:?set ALERT_EMAIL}

# 1. Container Insights add-on (EKS API directly; eksctl's OIDC pre-check is blocked by an SCP here).
#    Agents use the node role, which has CloudWatchAgentServerPolicy (nodegroup cloudWatch: true).
if ! aws eks describe-addon --region $R --cluster-name $C --addon-name amazon-cloudwatch-observability >/dev/null 2>&1; then
  aws eks create-addon --region $R --cluster-name $C --addon-name amazon-cloudwatch-observability >/dev/null
fi
aws eks wait addon-active --region $R --cluster-name $C --addon-name amazon-cloudwatch-observability
echo "add-on ACTIVE"

# 2. 7-day retention on the Container Insights log groups (they are created by Fluent Bit / the agent).
for g in application dataplane host performance; do
  aws logs put-retention-policy --region $R \
    --log-group-name /aws/containerinsights/$C/$g --retention-in-days 7 || echo "WARN: $g not created yet"
done

# 3. SNS topic + email subscription (confirm the email once).
TOPIC_ARN=$(aws sns create-topic --region $R --name streamingapp-alerts \
  --tags Key=project,Value=streamingapp --query TopicArn --output text)
aws sns subscribe --region $R --topic-arn "$TOPIC_ARN" --protocol email \
  --notification-endpoint "$ALERT_EMAIL" >/dev/null
A=(--alarm-actions "$TOPIC_ARN" --ok-actions "$TOPIC_ARN")

# 4. Alarms
aws cloudwatch put-metric-alarm --region $R --alarm-name streamingapp-node-cpu-high \
  --namespace ContainerInsights --metric-name node_cpu_utilization --dimensions Name=ClusterName,Value=$C \
  --statistic Average --period 300 --evaluation-periods 2 --threshold 80 \
  --comparison-operator GreaterThanThreshold --treat-missing-data missing "${A[@]}"

aws cloudwatch put-metric-alarm --region $R --alarm-name streamingapp-node-failed \
  --namespace ContainerInsights --metric-name cluster_failed_node_count --dimensions Name=ClusterName,Value=$C \
  --statistic Maximum --period 60 --evaluation-periods 3 --threshold 0 \
  --comparison-operator GreaterThanThreshold --treat-missing-data notBreaching "${A[@]}"

# 8 = sum of the HPA minimum replicas (auth 2, streaming 2, frontend 2, admin 1, chat 1)
aws cloudwatch put-metric-alarm --region $R --alarm-name streamingapp-pods-below-min \
  --namespace ContainerInsights --metric-name namespace_number_of_running_pods \
  --dimensions Name=ClusterName,Value=$C Name=Namespace,Value=$NS \
  --statistic Minimum --period 60 --evaluation-periods 3 --threshold 8 \
  --comparison-operator LessThanThreshold --treat-missing-data breaching "${A[@]}"

for s in auth streaming admin chat frontend; do
  aws cloudwatch put-metric-alarm --region $R --alarm-name streamingapp-restarts-$s \
    --namespace ContainerInsights --metric-name pod_number_of_container_restarts \
    --dimensions Name=ClusterName,Value=$C Name=Namespace,Value=$NS Name=PodName,Value=$s \
    --statistic Maximum --period 300 --evaluation-periods 1 --threshold 3 \
    --comparison-operator GreaterThanThreshold --treat-missing-data notBreaching "${A[@]}"
done

LB=$(aws elbv2 describe-load-balancers --region $R \
  --query "LoadBalancers[?contains(DNSName,'streamingapp-alb')].LoadBalancerArn" --output text | sed 's#.*:loadbalancer/##')
[ -n "$LB" ] || { echo "ALB not found"; exit 1; }
aws cloudwatch put-metric-alarm --region $R --alarm-name streamingapp-alb-5xx \
  --namespace AWS/ApplicationELB --metric-name HTTPCode_Target_5XX_Count --dimensions Name=LoadBalancer,Value=$LB \
  --statistic Sum --period 300 --evaluation-periods 1 --threshold 5 \
  --comparison-operator GreaterThanThreshold --treat-missing-data notBreaching "${A[@]}"

aws cloudwatch describe-alarms --region $R --alarm-name-prefix streamingapp- \
  --query 'MetricAlarms[].[AlarmName,StateValue]' --output table

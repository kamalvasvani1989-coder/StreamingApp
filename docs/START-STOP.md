# Start / stop runbook (cost saving)

The environment can be **paused** when nobody needs the live app and **resumed** before a demo or review. Everything runs from the laptop with the admin CLI profile `streamingapp`, using `infra/streamingapp-env.ps1`.

```powershell
cd $HOME\StreamingApp
powershell -ExecutionPolicy Bypass -File .\infra\streamingapp-env.ps1 -Action status
powershell -ExecutionPolicy Bypass -File .\infra\streamingapp-env.ps1 -Action pause
powershell -ExecutionPolicy Bypass -File .\infra\streamingapp-env.ps1 -Action resume
```

## What each action does

| Action | Steps | Time |
|---|---|---|
| `pause` | Disable alarm notifications → scale EKS nodegroup `ng-default` to 0 → stop Jenkins EC2 | ~5 min |
| `resume` | Start Jenkins EC2 → scale nodegroup to 2 → wait until `/healthz` and `/api/streaming/videos` return 200 → re-enable alarm notifications | ~5–10 min |
| `status` | Node count, Jenkins state, live-site HTTP codes, alarm state and whether notifications are on | seconds |

Alarm notifications are switched off while paused because `streamingapp-pods-below-min` would otherwise email an ALARM as soon as the nodes go away.

## What is kept while paused

| Kept | Why it survives |
|---|---|
| EKS cluster, Helm release, Kubernetes Secret, HPAs, Pod Identity | Only the worker nodes are removed. Pods go Pending and are rescheduled automatically when nodes return |
| ALB and its DNS name | The Ingress still exists, so the Cloudflare CNAME stays valid |
| Jenkins data and Elastic IP `3.104.137.60` | Instance is stopped, not terminated. The webhook URL and `ssh streamingapp` work again after resume |
| ECR images, S3 videos, MongoDB Atlas data, CloudWatch alarms and logs (7 days) | Not affected by the pause |

## Cost

| State | Approx. cost/day | Main items |
|---|---|---|
| Running | US$12–15 | EKS control plane, 3× m7i-flex.large, ALB, public IPv4, Container Insights |
| Paused | US$3.5–4 | EKS control plane (US$0.10/h, cannot be stopped), ALB, public IPv4 (ALB + Elastic IP), Jenkins EBS volume |
| Deleted | US$0 | See **Cost and teardown** in the README |

If the environment will not be needed for more than a week or two, a full teardown is cheaper. It can be rebuilt from this repository in about an hour by following the README.

## Rules while paused

- **Don't push to `main` without `[skip ci]`.** Jenkins is stopped, so the webhook delivery fails. If you resume and want that build, redeliver it from GitHub → Settings → Webhooks → Recent Deliveries.
- If Jenkins is running but the nodes are at 0, a deploy will fail and Helm `--atomic` rolls it back. Resume first, then push.
- The live URL returns an error while paused. That's expected.

## Troubleshooting after resume

```bash
ssh streamingapp
kubectl get nodes                                   # 2 nodes Ready
kubectl -n streamingapp get pods,hpa,ingress        # 8 pods Running
kubectl -n kube-system get pods                     # coredns, aws-load-balancer-controller, metrics-server Running
```

If pods stay Pending, check `kubectl describe pod <name>`. If the site returns 502/503 for a few minutes after the pods are Running, the ALB is still registering the new pod IPs; give it a couple of minutes.

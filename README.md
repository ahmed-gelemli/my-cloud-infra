# My Cloud Infrastructure

A Terraform-managed AWS infrastructure I built to host my personal projects. This is my attempt at learning cloud architecture and infrastructure-as-code. Definitely still learning, but I wanted to get hands-on experience with production-like setups rather than just following tutorials.

## What This Does

Essentially, this infrastructure lets me deploy multiple containerized apps (currently two: `eas` and `focusbee`) on a single EC2 instance behind a load balancer. Each app gets its own subdomain (like `eas.ismysimpleproject.com`) and HTTPS out of the box.

## Architecture Overview

```
                    ┌─────────────────┐
                    │   Route 53      │
                    │  (DNS Routing)  │
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
                    │  Application    │
                    │  Load Balancer  │
                    │  (HTTPS + HTTP) │
                    └────────┬────────┘
                             │ Host-based routing
              ┌──────────────┼──────────────┐
              │              │              │
    ┌─────────▼──────┐      ...      ┌──────▼─────────┐
    │  Target Group  │               │  Target Group  │
    │     (eas)      │               │   (focusbee)   │
    └─────────┬──────┘               └──────┬─────────┘
              │                             │
              └──────────────┬──────────────┘
                             │
                    ┌────────▼────────┐
                    │   ECS Cluster   │
                    │   (EC2-backed)  │
                    │   t3.micro      │
                    └─────────────────┘
```

## Key Components

### Compute (ECS on EC2)

I went with ECS on EC2 instead of Fargate mainly because it's cheaper for small workloads. Running a single t3.micro instance that hosts multiple containers using bridge networking and dynamic port mapping. The tradeoff is more complexity in setup, but I wanted to understand how ECS actually works under the hood.

### Networking & Security

- **ALB (Application Load Balancer)**: Handles incoming traffic and routes to the right container based on the hostname
- **Security Groups**: The ALB is open to the internet (ports 80/443), but the EC2 instance only accepts traffic from the ALB. This was one of those "aha" moments when I realized how security groups reference each other
- **HTTPS**: All HTTP traffic gets redirected to HTTPS. The ACM certificate is a wildcard cert validated through DNS

### Secrets Management

Each app has its own secret in AWS Secrets Manager. I set up IAM groups so that if I ever have collaborators, they can only access their app's secrets. The ECS tasks pull these secrets at runtime through the execution role.

### Container Registry

Using ECR to store Docker images. Each app has its own repository following the `{app}-service` naming convention.

### DNS

Route 53 manages the `ismysimpleproject.com` domain. Each app gets an A record alias pointing to the ALB, learned that aliases are faster and cheaper than CNAMEs for AWS resources.

## Things I Learned Building This

- **Dynamic port mapping**: Setting `hostPort = 0` lets Docker assign random ports, which is how you run multiple containers on one host. The ALB figures out where to send traffic through the target group registration.
- **IAM is everywhere**: Pretty much every AWS service needs some IAM role or policy. Getting the trust relationships right (who can assume what) took some trial and error.
- **The `for_each` meta-argument**: Made the code way cleaner than copy-pasting resources for each app. Adding a new app is just adding to the `local.apps` set.
- **DNS propagation takes time**: The ACM certificate validation through Route 53 was straightforward once I understood you need the CNAME records in place before validation completes.

## What I'd Do Differently / Future Improvements

- Set up CloudWatch alarms (currently have logging but no alerting for things like high CPU, failed health checks, etc.)
- Maybe look into Fargate for simpler scaling, though cost is still a factor
- Add a bastion host or SSM for debugging (right now I just check CloudWatch logs)
- Look into blue-green deployments with CodeDeploy. Currently using ECS's default rolling deployment.

## Cost

Currently covered by AWS credits, but actual usage runs around **~$50-55/month**:

| Service | Monthly Cost |
|---------|-------------|
| Public IPv4 addresses | ~$24 |
| Application Load Balancer | ~$16 |
| EC2 (t3.micro) | ~$7 |
| EBS storage | ~$3 |
| Secrets Manager (2 secrets) | ~$0.80 |
| Route 53 hosted zone | ~$0.50 |

---

*This is a personal learning project. The infrastructure works and hosts real apps, but I'm sure there are better ways to do some of this. Always open to feedback.*


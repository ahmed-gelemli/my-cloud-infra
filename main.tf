# Note: focusbee and readright projects will be added in the future
# Currently only deploying the eas service

# 1. Provider & Data Sources
provider "aws" {
  region = "us-east-1" # Change to your region
}

# Get default VPC and Subnets automatically
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# 2. ECR Repositories (Where your Docker images live)
resource "aws_ecr_repository" "repos" {
  for_each = toset(["eas-service"]) # "focusbee-service", "readright-service" commented out
  name     = each.key
}

# 3. Security Groups (The Firewalls)

# ALB Security Group: Open to the world on port 80
resource "aws_security_group" "alb_sg" {
  name        = "alb-security-group"
  description = "Allow HTTP inbound traffic"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EC2 Instance Security Group: Only allow traffic from ALB
resource "aws_security_group" "ecs_node_sg" {
  name        = "ecs-node-sg"
  description = "Allow traffic from ALB only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 0
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id] # The Critical Link!
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


# 4. ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "my-cluster"
}

# 5. IAM Role for EC2 (So it can talk to ECS)
data "aws_iam_policy_document" "ecs_agent" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_instance_role" {
  name               = "ecs-instance-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_agent.json
}

resource "aws_iam_role_policy_attachment" "ecs_agent" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "ecs_agent" {
  name = "ecs-agent-profile"
  role = aws_iam_role.ecs_instance_role.name
}

# 6. Launch Template (The blueprint for your Server)
# We need the "ECS-Optimized" AMI. This looks up the latest one automatically.
data "aws_ssm_parameter" "ecs_optimized_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/recommended/image_id"
}

resource "aws_launch_template" "ecs_nodes" {
  name_prefix   = "ecs-node-"
  image_id      = data.aws_ssm_parameter.ecs_optimized_ami.value
  instance_type = "t3.micro"
  
  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_agent.name
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.ecs_node_sg.id]
  }

  # This script registers the instance to your cluster named "my-cluster"
  user_data = base64encode(<<-EOF
              #!/bin/bash
              echo ECS_CLUSTER=${aws_ecs_cluster.main.name} >> /etc/ecs/ecs.config
              EOF
  )
}

# 7. Auto Scaling Group (Manages the EC2 creation)
resource "aws_autoscaling_group" "ecs_asg" {
  desired_capacity    = 1
  max_size            = 1
  min_size            = 1
  vpc_zone_identifier = data.aws_subnets.default.ids
  launch_template {
    id      = aws_launch_template.ecs_nodes.id
    version = "$Latest"
  }
}

# 8. Load Balancer
resource "aws_lb" "main" {
  name               = "main-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = data.aws_subnets.default.ids
}

# 9. Target Groups (The empty buckets for traffic)
resource "aws_lb_target_group" "apps" {
  for_each    = toset(["eas"]) # "focusbee", "readright" commented out
  name        = "${each.key}-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "instance" # Important for EC2 mode

  health_check {
    path = "/health"
  }
}

# 10. Listener (The Traffic Cop)
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  # Default action: Return 404 if no host matches
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "404: Not Found"
      status_code  = "404"
    }
  }
}

# 11. Listener Rules (Host-based Routing)
resource "aws_lb_listener_rule" "host_based_routing" {
  for_each     = toset(["eas"]) # "focusbee", "readright" commented out
  listener_arn = aws_lb_listener.http.arn

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.apps[each.key].arn
  }

  condition {
    host_header {
      values = ["${each.key}.ismysimpleproject.com"]
    }
  }
}
# 12. Task Definitions & Services
# We loop through your apps to save code
resource "aws_ecs_task_definition" "apps" {
  for_each                 = toset(["eas"]) # "focusbee", "readright" commented out
  family                   = each.key
  network_mode             = "bridge" # Required for dynamic host ports
  requires_compatibilities = ["EC2"]
  cpu                      = 256
  memory                   = 256 # Fits apps on a 1GB server easily

  container_definitions = jsonencode([
    {
      name      = each.key
      # In real life, use a variable for the image tag, e.g., ":latest" or ":v1"
      image     = "${aws_ecr_repository.repos["${each.key}-service"].repository_url}:latest"
      cpu       = 256
      memory    = 256
      essential = true
      portMappings = [
        {
          containerPort = 3000 # Your fixed internal port
          hostPort      = 0    # The Magic 0 for dynamic mapping
          protocol      = "tcp"
        }
      ]
    }
  ])
}

resource "aws_ecs_service" "apps" {
  for_each        = toset(["eas"]) # "focusbee", "readright" commented out
  name            = "${each.key}-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.apps[each.key].arn
  desired_count   = 1

  # Connects the service to the ALB Target Group
  load_balancer {
    target_group_arn = aws_lb_target_group.apps[each.key].arn
    container_name   = each.key
    container_port   = 3000
  }
  
  # Allow the service to be created even if the ALB isn't perfectly ready yet
  depends_on = [aws_lb_listener.http]
}

# 13. Route 53 Hosted Zone (The "Phone Book" for your domain)
resource "aws_route53_zone" "main" {
  name = "ismysimpleproject.com"
}

# 14. DNS Records (The "Entries" in the phone book)
# This loops through your apps and points "app.domain.com" -> ALB
resource "aws_route53_record" "app_aliases" {
  for_each = toset(["eas"]) # "focusbee", "readright" commented out
  
  zone_id = aws_route53_zone.main.zone_id
  name    = "${each.key}.ismysimpleproject.com" # e.g. eas.ismysimpleproject.com
  type    = "A"

  # The "Alias" block is AWS magic. It points to the ALB internally.
  # It is faster and cheaper than a CNAME record.
  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

# Output the Name Servers (You need these for Step 2)
output "nameservers" {
  value = aws_route53_zone.main.name_servers
}
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"

    }

  }
}

provider "aws" {
  region = var.region
}

###############################################################################
# 1. Networking – VPC (public subnets only)
###############################################################################
data "aws_availability_zones" "available" {}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.5"

  name = var.vpc_name
  cidr = var.vpc_cidr

  azs            = slice(data.aws_availability_zones.available.names, 0, 3)
  public_subnets = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, i)]

  enable_nat_gateway   = false
  enable_dns_support   = true
  enable_dns_hostnames = true
}

###############################################################################
# 2. Container registry – ECR
###############################################################################
resource "aws_ecr_repository" "repo" {
  name = var.ecr_name

  image_scanning_configuration {
    scan_on_push = true
  }

  lifecycle_policy {
    policy = jsonencode({
      rules = [{
        description  = "Delete untagged images after 30 days"
        rulePriority = 1
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countNumber = 30
          countUnit   = "days"

        }
        action = {
          type = "expire"
        }

      }]

    })

  }
}

###############################################################################
# 3. Logging – CloudWatch Log Group
###############################################################################
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.service_name}"
  retention_in_days = 30
}

###############################################################################
# 4. IAM – task-execution role
###############################################################################
data "aws_iam_policy_document" "ecs_task_execution_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

  }
}

resource "aws_iam_role" "ecs_task_execution" {
  name               = "${var.service_name}-task-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_execution_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_execution_attach" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

###############################################################################
# 5. ECS cluster
###############################################################################
resource "aws_ecs_cluster" "this" {
  name = var.cluster_name
}

###############################################################################
# 6. Security groups
###############################################################################
resource "aws_security_group" "alb" {
  name   = "${var.service_name}-alb-sg"
  vpc_id = module.vpc.vpc_id

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

resource "aws_security_group" "ecs" {
  name   = "${var.service_name}-ecs-sg"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

###############################################################################
# 7. Load Balancer (internet-facing)
###############################################################################
resource "aws_lb" "this" {
  name               = "${var.service_name}-alb"
  load_balancer_type = "application"
  subnets            = module.vpc.public_subnets
  security_groups    = [aws_security_group.alb.id]
}

resource "aws_lb_target_group" "this" {
  name        = "${var.service_name}-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  health_check {
    path                = "/"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 5
    unhealthy_threshold = 2

  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

###############################################################################
# 8. Task definition & Fargate service
###############################################################################
resource "aws_ecs_task_definition" "this" {
  family                   = var.service_name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"

  execution_role_arn = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([
    {
      name      = var.container_name
      image     = "${aws_ecr_repository.repo.repository_url}:latest" # push :latest first
      essential = true

      portMappings = [{
        containerPort = 8080, hostPort = 8080, protocol = "tcp"
      }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "ecs"

        }

      }

    }
  ])
}

resource "aws_ecs_service" "this" {
  name            = var.service_name
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc.public_subnets
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = true

  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = var.container_name
    container_port   = 8080

  }

  lifecycle {
    ignore_changes = [task_definition]
  } # clean rolling updates
}

###############################################################################
# 9. Variables & outputs
###############################################################################
variable "region" {
  type    = string
  default = "us-east-1"
}
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}
variable "vpc_name" {
  type    = string
  default = "demo-vpc"
}
variable "cluster_name" {
  type    = string
  default = "demo-cluster"
}
variable "service_name" {
  type    = string
  default = "demo-service"
}
variable "container_name" {
  type    = string
  default = "app"
}
variable "ecr_name" {
  type    = string
  default = "demo-repo"
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}
output "ecr_repository_url" {
  value = aws_ecr_repository.repo.repository_url
}

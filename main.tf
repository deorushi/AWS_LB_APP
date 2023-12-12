terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

# Configure the AWS Provider
provider "aws" {
  region = "us-east-1"
}

# VPC
resource "aws_vpc" "sh_main" {
  cidr_block = "10.0.0.0/23" # 512 IPs 
  tags = {
    Name = "sharmi-vpc"
  }
}

# Creating 1st public subnet 
resource "aws_subnet" "sh_subnet_1" {
  vpc_id                  = aws_vpc.sh_main.id
  cidr_block              = "10.0.0.0/27" #32 IPs
  map_public_ip_on_launch = true          # public subnet
  availability_zone       = "us-east-1a"
}
# Creating 2nd public subnet 
resource "aws_subnet" "sh_subnet_1a" {
  vpc_id                  = aws_vpc.sh_main.id
  cidr_block              = "10.0.0.32/27" #32 IPs
  map_public_ip_on_launch = true           # public subnet
  availability_zone       = "us-east-1b"
}
# Creating 1st private subnet 
resource "aws_subnet" "sh_subnet_2" {
  vpc_id                  = aws_vpc.sh_main.id
  cidr_block              = "10.0.1.0/27" #32 IPs
  map_public_ip_on_launch = false         # private subnet
  availability_zone       = "us-east-1b"
}

# Internet Gateway
resource "aws_internet_gateway" "sh_gw" {
  vpc_id = aws_vpc.sh_main.id
}

# route table for public subnet - connecting to Internet gateway
resource "aws_route_table" "sh_rt_public" {
  vpc_id = aws_vpc.sh_main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.sh_gw.id
  }
}

# associate the route table with public subnet 1
resource "aws_route_table_association" "sh_rta1" {
  subnet_id      = aws_subnet.sh_subnet_1.id
  route_table_id = aws_route_table.sh_rt_public.id
}
# associate the route table with public subnet 2
resource "aws_route_table_association" "sh_rta2" {
  subnet_id      = aws_subnet.sh_subnet_1a.id
  route_table_id = aws_route_table.sh_rt_public.id
}

# Elastic IP for NAT gateway
resource "aws_eip" "sh_eip" {
  depends_on = [aws_internet_gateway.sh_gw]
  vpc        = true
  tags = {
    Name = "sh_EIP_for_NAT"
  }
}

# NAT gateway for private subnets 
# (for the private subnet to access internet - eg. ec2 instances downloading softwares from internet)
resource "aws_nat_gateway" "sh_nat_for_private_subnet" {
  allocation_id = aws_eip.sh_eip.id
  subnet_id     = aws_subnet.sh_subnet_1.id # nat should be in public subnet

  tags = {
    Name = "Sh NAT for private subnet"
  }

  depends_on = [aws_internet_gateway.sh_gw]
}

# route table - connecting to NAT
resource "aws_route_table" "sh_rt_private" {
  vpc_id = aws_vpc.sh_main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.sh_nat_for_private_subnet.id
  }
}

# associate the route table with private subnet
resource "aws_route_table_association" "sh_rta3" {
  subnet_id      = aws_subnet.sh_subnet_2.id
  route_table_id = aws_route_table.sh_rt_private.id
}

resource "aws_lb" "sh_lb" {
  name               = "sharmi-lb-asg"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.sh_sg_for_elb.id]
  subnets            = [aws_subnet.sh_subnet_1.id, aws_subnet.sh_subnet_1a.id]
  depends_on         = [aws_internet_gateway.sh_gw]
}

resource "aws_lb_target_group" "sh_alb_tg" {
  name     = "sh-tf-lb-alb-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.sh_main.id
}

resource "aws_lb_listener" "sh_front_end" {
  load_balancer_arn = aws_lb.sh_lb.arn
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.sh_alb_tg.arn
  }
}

# ASG with Launch template
resource "aws_launch_template" "sh_ec2_launch_templ" {
  name_prefix   = "sh_ec2_launch_templ"
  image_id      = "ami-00c39f71452c08778" # To note: AMI is specific for each region
  instance_type = "t2.micro"
  user_data     = filebase64("user_data.sh")

  network_interfaces {
    associate_public_ip_address = false
    subnet_id                   = aws_subnet.sh_subnet_2.id
    security_groups             = [aws_security_group.sh_sg_for_ec2.id]
  }
  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "Sharmi-instance" # Name for the EC2 instances
    }
  }
}

resource "aws_autoscaling_group" "sh_asg" {
  # no of instances
  desired_capacity = 1
  max_size         = 1
  min_size         = 1

  # Connect to the target group
  target_group_arns = [aws_lb_target_group.sh_alb_tg.arn]

  vpc_zone_identifier = [ # Creating EC2 instances in private subnet
    aws_subnet.sh_subnet_2.id
  ]

  launch_template {
    id      = aws_launch_template.sh_ec2_launch_templ.id
    version = "$Latest"
  }
}

resource "aws_security_group" "sh_sg_for_elb" {
  name   = "sharmi-sg_for_elb"
  vpc_id = aws_vpc.sh_main.id

  ingress {
    description      = "Allow http request from anywhere"
    protocol         = "tcp"
    from_port        = 80
    to_port          = 80
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
    description      = "Allow https request from anywhere"
    protocol         = "tcp"
    from_port        = 443
    to_port          = 443
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

}

resource "aws_security_group" "sh_sg_for_ec2" {
  name   = "sharmi-sg_for_ec2"
  vpc_id = aws_vpc.sh_main.id

  ingress {
    description     = "Allow http request from Load Balancer"
    protocol        = "tcp"
    from_port       = 80 # range of
    to_port         = 80 # port numbers
    security_groups = [aws_security_group.sh_sg_for_elb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
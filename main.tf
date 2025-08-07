provider "aws" {
  region = "ap-south-1"
}

# ===============================
# 1. VPC Setup
# ===============================
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"

  name = "test-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["ap-south-1a", "ap-south-1b"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.11.0/24", "10.0.12.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }

  public_subnet_tags  = { Type = "public" }
  private_subnet_tags = { Type = "private" }
}

# ===============================
# 2. Security Groups
# ===============================

# NLB Security Group
resource "aws_security_group" "nlb_sg" {
  name        = "nlb-sg"
  description = "Allow VPN & SSH to NLB"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 1194
    to_port     = 1194
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 1194
    to_port     = 1194
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # TCP health check
  }

  ingress {
    from_port   = 22
    to_port     = 22
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

# OpenVPN Instance Security Group - fully open
resource "aws_security_group" "openvpn_sg" {
  name        = "openvpn-sg"
  description = "Allow all traffic to OpenVPN EC2"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ===============================
# 3. OpenVPN EC2 Instances
# ===============================
resource "aws_instance" "openvpn" {
  count         = 2
  ami           = "ami-0d0ad8bb301edb745" # Amazon Linux 2 x86_64
  instance_type = "t3.micro"
  subnet_id     = module.vpc.private_subnets[count.index]
  key_name      = "tfkey"  # Replace with your key pair name

  vpc_security_group_ids = [aws_security_group.openvpn_sg.id]

  user_data = <<-EOF
              #!/bin/bash
              set -e

              yum update -y
              yum install -y nc openvpn iptables iproute

              # ===== OpenVPN setup =====
              cat <<EOT >/etc/openvpn/server/server.conf
              port 1194
              proto udp
              dev tun
              server 10.8.0.0 255.255.255.0
              push "route 10.0.11.0 255.255.255.0"
              push "route 10.0.12.0 255.255.255.0"
              keepalive 10 120
              persist-key
              persist-tun
              user nobody
              group nobody
              status /var/log/openvpn-status.log
              log-append /var/log/openvpn.log
              verb 3
              EOT

              # Enable IP forwarding
              echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
              sysctl -p

              # Enable and start OpenVPN server
              systemctl enable openvpn-server@server
              systemctl start openvpn-server@server

              # ===== TCP responder on port 1194 for NLB health check =====
              cat <<'EOT' > /etc/systemd/system/openvpn-health.service
              [Unit]
              Description=OpenVPN NLB Health Check Listener on 1194
              After=network.target

              [Service]
              ExecStart=/bin/bash -c "while true; do echo -e 'OK\\r\\n' | nc -l -p 1194 -q 1; done"
              Restart=always

              [Install]
              WantedBy=multi-user.target
              EOT

              systemctl daemon-reload
              systemctl enable openvpn-health
              systemctl start openvpn-health
              EOF

  tags = {
    Name = "openvpn-${count.index}"
  }
}

# ===============================
# 4. Primary NLB
# ===============================
resource "aws_lb" "nlb_primary" {
  name               = "openvpn-nlb-primary"
  load_balancer_type = "network"
  subnets            = module.vpc.public_subnets
  enable_cross_zone_load_balancing = true
}

# OpenVPN TG
resource "aws_lb_target_group" "openvpn_tg_primary" {
  name        = "openvpn-tcpudp-tg-primary"
  port        = 1194
  protocol    = "TCP_UDP"
  vpc_id      = module.vpc.vpc_id
  target_type = "instance"

  health_check {
    protocol = "TCP"
    port     = "1194"
  }
}

# SSH TG
resource "aws_lb_target_group" "ssh_tg_primary" {
  name        = "openvpn-ssh-tg-primary"
  port        = 22
  protocol    = "TCP"
  vpc_id      = module.vpc.vpc_id
  target_type = "instance"

  health_check {
    protocol = "TCP"
    port     = "22"
  }
}

# Attachments
resource "aws_lb_target_group_attachment" "openvpn_attach_primary" {
  target_group_arn = aws_lb_target_group.openvpn_tg_primary.arn
  target_id        = aws_instance.openvpn[0].id
  port             = 1194
}

resource "aws_lb_target_group_attachment" "ssh_attach_primary" {
  target_group_arn = aws_lb_target_group.ssh_tg_primary.arn
  target_id        = aws_instance.openvpn[0].id
  port             = 22
}

# Listeners
resource "aws_lb_listener" "udp_listener_primary" {
  load_balancer_arn = aws_lb.nlb_primary.arn
  port              = 1194
  protocol          = "UDP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.openvpn_tg_primary.arn
  }
}

resource "aws_lb_listener" "ssh_listener_primary" {
  load_balancer_arn = aws_lb.nlb_primary.arn
  port              = 22
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ssh_tg_primary.arn
  }
}

# ===============================
# 5. Secondary NLB
# ===============================
resource "aws_lb" "nlb_secondary" {
  name               = "openvpn-nlb-secondary"
  load_balancer_type = "network"
  subnets            = module.vpc.public_subnets
  enable_cross_zone_load_balancing = true
}

resource "aws_lb_target_group" "openvpn_tg_secondary" {
  name        = "openvpn-tcpudp-tg-secondary"
  port        = 1194
  protocol    = "TCP_UDP"
  vpc_id      = module.vpc.vpc_id
  target_type = "instance"

  health_check {
    protocol = "TCP"
    port     = "1194"
  }
}

resource "aws_lb_target_group" "ssh_tg_secondary" {
  name        = "openvpn-ssh-tg-secondary"
  port        = 22
  protocol    = "TCP"
  vpc_id      = module.vpc.vpc_id
  target_type = "instance"

  health_check {
    protocol = "TCP"
    port     = "22"
  }
}

resource "aws_lb_target_group_attachment" "openvpn_attach_secondary" {
  target_group_arn = aws_lb_target_group.openvpn_tg_secondary.arn
  target_id        = aws_instance.openvpn[1].id
  port             = 1194
}

resource "aws_lb_target_group_attachment" "ssh_attach_secondary" {
  target_group_arn = aws_lb_target_group.ssh_tg_secondary.arn
  target_id        = aws_instance.openvpn[1].id
  port             = 22
}

resource "aws_lb_listener" "udp_listener_secondary" {
  load_balancer_arn = aws_lb.nlb_secondary.arn
  port              = 1194
  protocol          = "UDP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.openvpn_tg_secondary.arn
  }
}

resource "aws_lb_listener" "ssh_listener_secondary" {
  load_balancer_arn = aws_lb.nlb_secondary.arn
  port              = 22
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ssh_tg_secondary.arn
  }
}

# ===============================
# 6. Route53 Failover Records
# ===============================
resource "aws_route53_record" "vpn_primary" {
  zone_id = "Z0259799296D7PA0JE29K"  # Replace with your hosted zone ID
  name    = "openvpn"
  type    = "A"

  set_identifier = "primary"
  failover_routing_policy { type = "PRIMARY" }

  alias {
    name                   = aws_lb.nlb_primary.dns_name
    zone_id                = aws_lb.nlb_primary.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "vpn_secondary" {
  zone_id = "Z0259799296D7PA0JE29K"
  name    = "openvpn"
  type    = "A"

  set_identifier = "secondary"
  failover_routing_policy { type = "SECONDARY" }

  alias {
    name                   = aws_lb.nlb_secondary.dns_name
    zone_id                = aws_lb.nlb_secondary.zone_id
    evaluate_target_health = true
  }
}


##### private vms

# Security group for private instances (SSH from OpenVPN only)
resource "aws_security_group" "private_instance_sg" {
  name        = "private-instance-sg"
  description = "Allow SSH from OpenVPN EC2 instances"
  vpc_id      = module.vpc.vpc_id

  # SSH from OpenVPN SG
  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.openvpn_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "private-instance-sg"
  }
}


resource "aws_instance" "private_vm" {
  count         = 2
  ami           = "ami-0d0ad8bb301edb745" # Amazon Linux 2
  instance_type = "t3.micro"
  subnet_id     = module.vpc.private_subnets[count.index]
  key_name      = "tfkey"  # Replace with your key pair

  vpc_security_group_ids = [aws_security_group.private_instance_sg.id]

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y nc
              # SSH ready; nothing special
              EOF

  tags = {
    Name = "private-vm-${count.index}"
  }
}


resource "aws_lb" "nlb_private" {
  name               = "private-vm-nlb"
  load_balancer_type = "network"
  subnets            = module.vpc.public_subnets
  enable_cross_zone_load_balancing = true
}

# Target group for SSH
resource "aws_lb_target_group" "private_vm_tg" {
  name        = "private-vm-tg"
  port        = 22
  protocol    = "TCP"
  vpc_id      = module.vpc.vpc_id
  target_type = "instance"

  health_check {
    protocol = "TCP"
    port     = "22"
  }
}

# Attach instances
resource "aws_lb_target_group_attachment" "private_vm_attach" {
  count            = 2
  target_group_arn = aws_lb_target_group.private_vm_tg.arn
  target_id        = aws_instance.private_vm[count.index].id
  port             = 22
}

# Listener for SSH
resource "aws_lb_listener" "ssh_listener_private" {
  load_balancer_arn = aws_lb.nlb_private.arn
  port              = 22
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.private_vm_tg.arn
  }
}



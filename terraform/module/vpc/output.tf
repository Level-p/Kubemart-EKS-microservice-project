output "vpc_id" {
  value = aws_vpc.vpc.id
}

output "vpc_cidr_block" {
  value = aws_vpc.vpc.cidr_block
}

output "public_subnet_ids" {
  value = { for k, s in aws_subnet.public_subs : k => s.id }
}

output "private_subnet_ids" {
  value = { for k, s in aws_subnet.private_subs : k => s.id }
}

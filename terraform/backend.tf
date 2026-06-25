# Uncomment after creating an S3 bucket for state storage.
# For this assignment, local state is used by default.
#
# terraform {
#   backend "s3" {
#     bucket         = "icounter-terraform-state"
#     key            = "eks/terraform.tfstate"
#     region         = "ap-south-1"
#     encrypt        = true
#     dynamodb_table = "icounter-terraform-lock"
#   }
# }

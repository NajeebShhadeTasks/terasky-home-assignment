terraform {
  required_version = ">= 1.5.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
  }

  # Remote state with locking. The bucket + lock table are created once by
  # scripts/bootstrap-state.sh (chicken-and-egg: state storage cannot manage itself).
  backend "s3" {
    bucket         = "terasky-demo-tfstate-647604014014"
    key            = "terasky-home-assignment/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "terasky-demo-tf-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "terasky-home-assignment"
      ManagedBy = "terraform"
      Repo      = "github.com/${var.github_owner}/${var.github_repository}"
    }
  }
}

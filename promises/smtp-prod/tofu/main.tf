terraform {
  required_version = "= 1.12.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.73.0"
    }
  }

  # Bucket, key and region are supplied by the pipeline with -backend-config.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type = string
}

variable "name" {
  description = "Name of the IAM user holding the SMTP credentials; must start with smtp-."
  type        = string

  validation {
    condition     = can(regex("^smtp-[a-z0-9]{12}$", var.name))
    error_message = "The name must be smtp- followed by 12 lowercase hex characters."
  }
}

variable "from_address" {
  type = string
}

variable "to_address" {
  type = string
}

variable "tags" {
  type = map(string)
}

# The platform owns and verifies the sender and recipient identities (infra/platform/ses.tf).
# Credentials are only issued once both are verified, which SES requires for sending from the
# sender identity and, while the account is in the SES sandbox, to the recipient.
data "aws_sesv2_email_identity" "address" {
  for_each       = toset([var.from_address, var.to_address])
  email_identity = each.value

  lifecycle {
    postcondition {
      condition     = self.verified_for_sending_status
      error_message = "The SES identity ${each.value} is missing or not verified; the platform must verify it first."
    }
  }
}

# SMTP credentials are an IAM access key allowed to send only as the sender identity.
resource "aws_iam_user" "smtp" {
  name = var.name
  path = "/smtp-prod/"
  tags = var.tags
}

data "aws_iam_policy_document" "send" {
  statement {
    actions   = ["ses:SendRawEmail"]
    resources = [data.aws_sesv2_email_identity.address[var.from_address].arn]
  }
}

resource "aws_iam_user_policy" "send" {
  name   = "send-notifications"
  user   = aws_iam_user.smtp.name
  policy = data.aws_iam_policy_document.send.json
}

resource "aws_iam_access_key" "smtp" {
  user = aws_iam_user.smtp.name

  depends_on = [aws_iam_user_policy.send]
}

output "host" {
  value = "email-smtp.${var.aws_region}.amazonaws.com"
}

output "username" {
  value = aws_iam_access_key.smtp.id
}

output "password" {
  value     = aws_iam_access_key.smtp.ses_smtp_password_v4
  sensitive = true
}

output "sender_verified" {
  value = data.aws_sesv2_email_identity.address[var.from_address].verified_for_sending_status
}

output "recipient_verified" {
  value = data.aws_sesv2_email_identity.address[var.to_address].verified_for_sending_status
}

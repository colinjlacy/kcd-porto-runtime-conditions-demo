# The SES sender and recipient identities belong to the platform so they are verified once
# rather than on every demo build. Each address is verified by SES emailing it a confirmation
# link; the smtp-prod Promise only checks that they are verified before issuing credentials.
resource "aws_sesv2_email_identity" "notification" {
  for_each       = toset([var.notification_from_address, var.notification_to_address])
  email_identity = each.value
}

output "ses_identities" {
  description = "SES identities the smtp-prod Promise sends from and to, with their verification status."
  value       = { for address, identity in aws_sesv2_email_identity.notification : address => identity.verified_for_sending_status }
}

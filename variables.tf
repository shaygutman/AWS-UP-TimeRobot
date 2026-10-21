variable "aws_region" {
  description = "AWS region for the monitors and the alert topic."
  type        = string
  default     = "us-east-1"
}

variable "alert_emails" {
  description = "Email addresses that receive alerts. Each person must click the confirmation link AWS sends. Keep the real list in terraform.tfvars, not in git."
  type        = list(string)

  validation {
    condition = length(var.alert_emails) > 0 && alltrue([
      for email in var.alert_emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", email))
    ])
    error_message = "alert_emails must contain at least one address that looks like an email."
  }
}

variable "alert_sms_numbers" {
  description = "Mobile numbers that receive text alerts, in international form such as +9725XXXXXXXX. Keep the real list in terraform.tfvars, not in git."
  type        = list(string)

  validation {
    condition = length(var.alert_sms_numbers) > 0 && alltrue([
      for number in var.alert_sms_numbers : can(regex("^\\+972[1-9][0-9]{8}$", number))
    ])
    error_message = "Each SMS number must be an Israeli number in international form, like +9725XXXXXXXX."
  }
}

variable "consecutive_failures" {
  description = "How many failed checks in a row are required before an alert is sent. Checks run every 3 minutes."
  type        = number
  default     = 2

  validation {
    condition     = var.consecutive_failures >= 1 && var.consecutive_failures <= 10
    error_message = "consecutive_failures must be from 1 to 10."
  }
}

variable "notify_on_recovery" {
  description = "Also send an email when a check succeeds again after an alert."
  type        = bool
  default     = true
}

variable "http_url" {
  description = "HTTPS address checked every 3 minutes."
  type        = string
  default     = "https://portal.givenimaging.com/RapidRegistration"

  validation {
    condition     = startswith(var.http_url, "https://")
    error_message = "http_url must start with https://."
  }
}

variable "tcp_host" {
  description = "Host name for the TCP port check."
  type        = string
  default     = "PRD.given.co.il"
}

variable "tcp_port" {
  description = "TCP port that must accept a connection."
  type        = number
  default     = 7080

  validation {
    condition     = var.tcp_port > 0 && var.tcp_port < 65536
    error_message = "tcp_port must be a valid port number."
  }
}

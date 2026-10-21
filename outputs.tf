output "sns_topic_arn" {
  description = "Alert topic. Each email recipient must confirm the subscription before mail is delivered."
  value       = aws_sns_topic.alerts.arn
}

output "alert_recipient_counts" {
  description = "How many email and text subscriptions are configured."
  value = {
    email = length(aws_sns_topic_subscription.email)
    sms   = length(aws_sns_topic_subscription.sms)
  }
}

output "https_canary_name" {
  description = "CloudWatch Synthetics canary that checks the registration portal."
  value       = aws_synthetics_canary.https.name
}

output "tcp_checker_name" {
  description = "Function that checks whether the TCP port accepts a connection."
  value       = aws_lambda_function.tcp_check.function_name
}

output "https_alarm_name" {
  description = "Alarm that sends an alert after repeated HTTPS failures."
  value       = aws_cloudwatch_metric_alarm.https.alarm_name
}

output "tcp_alarm_name" {
  description = "Alarm that sends an alert after repeated TCP failures."
  value       = aws_cloudwatch_metric_alarm.tcp.alarm_name
}

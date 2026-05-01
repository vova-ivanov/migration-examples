variable "name" {
  type        = string
  description = "Function name and IAM role name prefix."
}

variable "lambda_zip" {
  type        = string
  description = "Path to the deployment ZIP archive."
}

variable "environment" {
  type        = map(string)
  default     = {}
  description = "Lambda environment variables."
}

variable "timeout" {
  type    = number
  default = 30
}

variable "memory_size" {
  type    = number
  default = 128
}

variable "tags" {
  type    = map(string)
  default = {}
}

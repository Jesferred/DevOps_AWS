variable "domain_name" {
  description = "Apex domain of the public hosted zone."
  type        = string
}

variable "ttl" {
  description = "Default TTL for records in seconds."
  type        = number
  default     = 300
}

variable "mx_records" {
  description = "MX records in '<priority> <host>' form."
  type        = list(string)
}

variable "spf_record" {
  description = "SPF policy for the apex domain."
  type        = string
}

variable "dkim_records" {
  description = "DKIM public keys keyed by selector, e.g. { default = \"v=DKIM1; k=rsa; p=...\" }."
  type        = map(string)
  default     = {}
}

variable "dmarc_record" {
  description = "DMARC policy published at _dmarc.<domain>."
  type        = string
}

variable "caa_records" {
  description = "CAA records restricting which CAs may issue certificates for the domain."
  type        = list(string)
}

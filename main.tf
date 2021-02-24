# ---------------------------------------------------------------------------------------------------------------------
# LAUNCH A LOAD BALANCER WITH INSTANCE GROUP AND STORAGE BUCKET BACKEND
#
# This is an example of how to use the http-load-balancer module to deploy a HTTP load balancer
# with multiple backends and optionally ssl and custom domain.
# ---------------------------------------------------------------------------------------------------------------------

terraform {
  # This module is now only being tested with Terraform 0.13.x. However, to make upgrading easier, we are setting
  # 0.12.26 as the minimum version, as that version added support for required_providers with source URLs, making it
  # forwards compatible with 0.13.x code.
  required_version = ">= 0.12.26"
}

# ------------------------------------------------------------------------------
# CONFIGURE OUR GCP CONNECTION
# ------------------------------------------------------------------------------

provider "google" {
  version = "~> 3.43.0"
  region  = var.region
  project = var.project
}

provider "google-beta" {
  version = "~> 3.43.0"
  region  = var.region
  project = var.project
}

# ------------------------------------------------------------------------------
# CREATE THE LOAD BALANCER
# ------------------------------------------------------------------------------

module "lb" {
  source                = "./modules/http-load-balancer"
  name                  = var.name
  project               = var.project
  url_map               = google_compute_url_map.urlmap.self_link
  dns_managed_zone_name = var.dns_managed_zone_name
  custom_domain_names   = [var.custom_domain_name]
  create_dns_entries    = var.create_dns_entry
  dns_record_ttl        = var.dns_record_ttl
  enable_http           = var.enable_http
  enable_ssl            = var.enable_ssl
  ssl_certificates      = google_compute_ssl_certificate.certificate.*.self_link

  custom_labels = var.custom_labels
}

# ------------------------------------------------------------------------------
# CREATE THE URL MAP TO MAP PATHS TO BACKENDS
# ------------------------------------------------------------------------------

resource "google_compute_url_map" "urlmap" {
  project = var.project

  name        = "${var.name}-url-map"
  description = "URL map for ${var.name}"

  default_service = google_compute_backend_service.microservice.id

  host_rule {
    hosts        = ["*.jon-deploy.com"]
    path_matcher = "microservice"
  }

  host_rule {
    hosts        = ["api.jon-deploy.com"]
    path_matcher = "api"
  }

  path_matcher {
    name            = "microservice"
    default_service = google_compute_backend_service.microservice.id

    path_rule {
      paths   = ["/ingest/start"]
      service = google_compute_backend_service.microservice.id
    }
  }
  
  path_matcher {
    name            = "api"
    default_service = google_compute_backend_service.api.id

    path_rule {
      paths   = ["/ingest/*"]
      service = google_compute_backend_service.api.id
    }
  }
}

# ------------------------------------------------------------------------------
# CONFIGURE HEALTH CHECK FOR THE API BACKEND
# ------------------------------------------------------------------------------

# resource "google_compute_health_check" "default" {
#   project = var.project
#   name    = "${var.name}-hc"

#   http_health_check {
#     port         = 5000
#     request_path = "/api"
#   }

#   check_interval_sec = 5
#   timeout_sec        = 5
# }

# ------------------------------------------------------------------------------
# CREATE THE STORAGE BUCKET FOR THE STATIC CONTENT
# ------------------------------------------------------------------------------

# resource "google_storage_bucket" "static" {
#   project = var.project

#   name          = "${var.name}-bucket"
#   location      = var.static_content_bucket_location
#   storage_class = "MULTI_REGIONAL"

#   website {
#     main_page_suffix = "index.html"
#     not_found_page   = "404.html"
#   }

#   # For the example, we want to clean up all resources. In production, you should set this to false to prevent
#   # accidental loss of data
#   force_destroy = true

#   labels = var.custom_labels
# }

# ------------------------------------------------------------------------------
# CREATE THE BACKEND FOR THE STORAGE BUCKET
# ------------------------------------------------------------------------------

# resource "google_compute_backend_bucket" "static" {
#   project = var.project

#   name        = "${var.name}-backend-bucket"
#   bucket_name = google_storage_bucket.static.name
# }

# # ------------------------------------------------------------------------------
# # UPLOAD SAMPLE CONTENT WITH PUBLIC READ ACCESS
# # ------------------------------------------------------------------------------

# resource "google_storage_default_object_acl" "website_acl" {
#   bucket      = google_storage_bucket.static.name
#   role_entity = ["READER:allUsers"]
# }

# resource "google_storage_bucket_object" "index" {
#   name    = "index.html"
#   content = "Hello, World!"
#   bucket  = google_storage_bucket.static.name

#   # We have to depend on the ACL because otherwise the ACL could get created after the object
#   depends_on = [google_storage_default_object_acl.website_acl]
# }

# resource "google_storage_bucket_object" "not_found" {
#   name    = "404.html"
#   content = "Uh oh"
#   bucket  = google_storage_bucket.static.name

#   # We have to depend on the ACL because otherwise the ACL could get created after the object
#   depends_on = [google_storage_default_object_acl.website_acl]
# }

# ------------------------------------------------------------------------------
# IF SSL IS ENABLED, CREATE A SELF-SIGNED CERTIFICATE
# ------------------------------------------------------------------------------

resource "tls_self_signed_cert" "cert" {
  # Only create if SSL is enabled
  count = var.enable_ssl ? 1 : 0

  key_algorithm   = "RSA"
  private_key_pem = join("", tls_private_key.private_key.*.private_key_pem)

  subject {
    common_name  = var.custom_domain_name
    organization = "Examples, Inc"
  }

  validity_period_hours = 12

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

resource "tls_private_key" "private_key" {
  count       = var.enable_ssl ? 1 : 0
  algorithm   = "RSA"
  ecdsa_curve = "P256"
}

# ------------------------------------------------------------------------------
# CREATE A CORRESPONDING GOOGLE CERTIFICATE THAT WE CAN ATTACH TO THE LOAD BALANCER
# ------------------------------------------------------------------------------

resource "google_compute_ssl_certificate" "certificate" {
  project = var.project

  count = var.enable_ssl ? 1 : 0

  name_prefix = var.name
  description = "SSL Certificate"
  private_key = join("", tls_private_key.private_key.*.private_key_pem)
  certificate = join("", tls_self_signed_cert.cert.*.cert_pem)

  lifecycle {
    create_before_destroy = true
  }
}

# ------------------------------------------------------------------------------
# CREATE THE INSTANCE GROUP WITH A SINGLE INSTANCE AND THE BACKEND SERVICE CONFIGURATION
# We use the instance group only to highlight the ability to specify multiple types
# of backends for the load balancer
# ------------------------------------------------------------------------------

resource "google_compute_region_network_endpoint_group" "microservice_proxy" {
  provider=google-beta
  name                  = "microserevice-endpoint"
  network_endpoint_type = "SERVERLESS"
  region                = var.region
  cloud_run {
    url_mask            = var.url_mask
  }
}

resource "google_compute_region_network_endpoint_group" "api_proxy" {
  provider=google-beta
  name                  = "api-endpoint"
  network_endpoint_type = "SERVERLESS"
  region                = var.api-region
  cloud_run {
    url_mask            = var.url_mask
  }
}

# resource "google_compute_region_network_endpoint" "proxy" {
#   provider=google-beta
#   global_network_endpoint_group = google_compute_global_network_endpoint_group.external_proxy.id
#   fqdn                          = "jon-deploy.com"
#   port                          = google_compute_global_network_endpoint_group.external_proxy.default_port
# }

resource "google_compute_backend_service" "microservice" {
  provider=google-beta
  name                            = "microservice-backend"
  enable_cdn                      = true

  # custom_request_headers          = ["host: ${google_compute_global_network_endpoint.proxy.fqdn}"]
  # custom_response_headers         = ["X-Cache-Hit: {cdn_cache_status}"]

  backend {
    group = google_compute_region_network_endpoint_group.microservice_proxy.id
  }
}

resource "google_compute_backend_service" "api" {
  provider=google-beta
  name                            = "tf-api-backend"
  enable_cdn                      = true

  # custom_request_headers          = ["host: ${google_compute_global_network_endpoint.proxy.fqdn}"]
  # custom_response_headers         = ["X-Cache-Hit: {cdn_cache_status}"]

  backend {
    group = google_compute_region_network_endpoint_group.api_proxy.id
  }
}


# resource "google_compute_instance_group" "api" {
#   project   = var.project
#   name      = "${var.name}-instance-group"
#   zone      = var.zone
#   instances = [google_compute_instance.api.self_link]

#   lifecycle {
#     create_before_destroy = true
#   }

#   named_port {
#     name = "http"
#     port = 5000
#   }
# }

# resource "google_compute_instance" "api" {
#   project      = var.project
#   name         = "${var.name}-instance"
#   machine_type = "f1-micro"
#   zone         = var.zone

#   # We're tagging the instance with the tag specified in the firewall rule
#   tags = ["private-app"]

#   boot_disk {
#     initialize_params {
#       image = "debian-cloud/debian-9"
#     }
#   }

#   # Make sure we have the flask application running
#   metadata_startup_script = file("${path.module}/examples/shared/startup_script.sh")

#   # Launch the instance in the default subnetwork
#   network_interface {
#     subnetwork = "default"

#     # This gives the instance a public IP address for internet connectivity. Normally, you would have a Cloud NAT,
#     # but for the sake of simplicity, we're assigning a public IP to get internet connectivity
#     # to be able to run startup scripts
#     access_config {
#     }
#   }
# }

# ------------------------------------------------------------------------------
# CREATE A FIREWALL TO ALLOW ACCESS FROM THE LB TO THE INSTANCE
# ------------------------------------------------------------------------------

resource "google_compute_firewall" "firewall" {
  project = var.project
  name    = "${var.name}-fw"
  network = "default"

  # Allow load balancer access to the API instances
  # https://cloud.google.com/load-balancing/docs/https/#firewall_rules
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]

  target_tags = ["private-app"]
  source_tags = ["private-app"]

  allow {
    protocol = "tcp"
    ports    = ["5000"]
  }
}
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  # Authentication uses Application Default Credentials (ADC).
  # Locally:  gcloud auth application-default login
  # In CI:    a service-account key or Workload Identity Federation.
}

# Dataform resources are only in the beta provider.
provider "google-beta" {
  project = var.project_id
  region  = var.region
}

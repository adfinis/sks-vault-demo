module "sks" {
  source  = "camptocamp/sks/exoscale"
  version = "~> 0.4"

  name               = "andreasg-hug-meetup"
  zone               = "ch-dk-2" # Zurich, `exo zone`
  kubernetes_version = "1.25.4"

  nodepools = {
    "router" = {
      instance_type = "standard.small" # `exo compute instance-type list`
      size          = 2
    },
    "compute" = {
      instance_type = "standard.small"
      size          = 3
    },
  }
}

output "kubeconfig" {
  value     = module.sks.kubeconfig
  sensitive = true
}

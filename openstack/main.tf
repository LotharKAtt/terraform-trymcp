# Configure the OpenStack Provider
provider "openstack" {
  auth_url    = "${var.openstack_auth_url}"
  password    = "${var.openstack_password}"
  tenant_name = "${var.openstack_tenant_name}"
  user_name   = "${var.openstack_user_name}"
}

# Create Keypair
resource "openstack_compute_keypair_v2" "keypair" {
  name       = "${var.cluster_name}-keypair"
  public_key = "${file(var.keypair_public_key)}"
}

# Create Security Group
resource "openstack_compute_secgroup_v2" "secgroup" {
  name        = "${var.cluster_name}-secgroup"
  description = "Security Group got training-lab for ${var.cluster_name}"

  rule {
    from_port   = 1
    to_port     = 65535
    ip_protocol = "udp"
    cidr        = "0.0.0.0/0"
  }

  rule {
    from_port   = 1
    to_port     = 65535
    ip_protocol = "tcp"
    cidr        = "0.0.0.0/0"
  }

  rule {
    from_port   = -1
    to_port     = -1
    ip_protocol = "icmp"
    cidr        = "0.0.0.0/0"
  }
}

data "openstack_networking_network_v2" "external_network" {
  name = "${var.openstack_networking_network_external_network_name}"
}

# Create private network
resource "openstack_networking_network_v2" "private-network" {
  name           = "${format("%s-priv-network", var.cluster_name)}"
  admin_state_up = "true"
}

# Create private subnet
resource "openstack_networking_subnet_v2" "private-subnet" {
  name            = "${format("%s-priv-subnet", var.cluster_name)}"
  network_id      = "${openstack_networking_network_v2.private-network.id}"
  cidr            = "${var.openstack_networking_subnet_cidr}"
  dns_nameservers = "${var.openstack_networking_subnet_dns_nameservers}"
}

# Create router for private subnet
resource "openstack_networking_router_v2" "private-router" {
  name                = "${format("%s-priv-router", var.cluster_name)}"
  external_network_id = "${data.openstack_networking_network_v2.external_network.id}"
  admin_state_up      = "true"
}

# Create router interface for private subnet
resource "openstack_networking_router_interface_v2" "router-interface" {
  router_id  = "${openstack_networking_router_v2.private-router.id}"
  subnet_id  = "${openstack_networking_subnet_v2.private-subnet.id}"
}

# Create floating IP for Drivetrain node
resource "openstack_networking_floatingip_v2" "floatingip_drivetrain" {
  pool  = "${var.openstack_networking_floatingip}"
}

# Create floating IP for AIO node
resource "openstack_networking_floatingip_v2" "floatingip_aio" {
  pool  = "${var.openstack_networking_floatingip}"
}

# Create Drivetrain node
resource "openstack_compute_instance_v2" "vm_drivetrain" {
  name              = "${format("cfg01.%s", var.domain)}"
  image_name        = "${var.trymcp_drivetrain_image_name}"
  flavor_name       = "${var.trymcp_drivetrain_flavor_name}"
  availability_zone = "${var.openstack_availability_zone}"
  key_pair          = "${openstack_compute_keypair_v2.keypair.name}"
  security_groups   = ["${openstack_compute_secgroup_v2.secgroup.name}"]
  user_data         = "#cloud-config\nusers:\n  - name: ubuntu\n    ssh_authorized_keys:\n      - ${file(var.keypair_public_key)}"
  depends_on        = ["openstack_networking_router_interface_v2.router-interface"]

  network {
    uuid           = "${openstack_networking_network_v2.private-network.id}"
    fixed_ip_v4    = "${cidrhost(var.openstack_networking_subnet_cidr, 100)}"
    access_network = true
  }
}

# Create AIO node
resource "openstack_compute_instance_v2" "vm_aio" {
  name              = "${format("aio01.%s", var.domain)}"
  image_name        = "${var.trymcp_aio_image_name}"
  flavor_name       = "${var.trymcp_aio_flavor_name}"
  availability_zone = "${var.openstack_availability_zone}"
  key_pair          = "${openstack_compute_keypair_v2.keypair.name}"
  security_groups   = ["${openstack_compute_secgroup_v2.secgroup.name}"]
  user_data         = "#cloud-config\nusers:\n  - name: ubuntu\n    ssh_authorized_keys:\n      - ${file(var.keypair_public_key)}"
  depends_on        = ["openstack_networking_router_interface_v2.router-interface"]

  network {
    uuid           = "${openstack_networking_network_v2.private-network.id}"
    fixed_ip_v4    = "${cidrhost(var.openstack_networking_subnet_cidr, 101)}"
    access_network = true
  }
}

# Associate floating IP with Drivetrain node
resource "openstack_compute_floatingip_associate_v2" "floatingip_drivetrain" {
  floating_ip = "${openstack_networking_floatingip_v2.floatingip_drivetrain.address}"
  instance_id = "${openstack_compute_instance_v2.vm_drivetrain.id}"
}

# Associate floating IP with AIO nodes
resource "openstack_compute_floatingip_associate_v2" "floatingip_aio" {
  floating_ip = "${openstack_networking_floatingip_v2.floatingip_aio.address}"
  instance_id = "${openstack_compute_instance_v2.vm_aio.id}"
}

# Connect Salt minion on AIO node
resource "null_resource" "bootstrap_aio" {
  depends_on = ["openstack_compute_floatingip_associate_v2.floatingip_aio"]

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = "${file(var.keypair_private_key)}"
    host        = "${openstack_networking_floatingip_v2.floatingip_aio.address}"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo sh -c \"echo 'master: ${openstack_compute_instance_v2.vm_drivetrain.network.0.fixed_ip_v4}' >> /etc/salt/minion\"",
      "sudo service salt-minion restart"
    ]
  }
}

output "drivetrain_internal_ip" {
  description = "Drivetrain internal IP address"
  value = "${openstack_compute_instance_v2.vm_drivetrain.network.0.fixed_ip_v4}"
}

output "drivetrain_external_ip" {
  description = "Drivetrain external IP address"
  value = "${openstack_networking_floatingip_v2.floatingip_drivetrain.address}"
}

output "aio_internal_ip" {
  description = "AIO internal IP address"
  value = "${openstack_compute_instance_v2.vm_aio.network.0.fixed_ip_v4}"
}

output "aio_external_ip" {
  description = "AIO external IP address"
  value = "${openstack_networking_floatingip_v2.floatingip_aio.address}"
}

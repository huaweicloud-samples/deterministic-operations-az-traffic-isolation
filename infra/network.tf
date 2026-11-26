# ---------------------------------------------------------------------------
# 网络
#
# 每个可用区一对子网：一个放负载均衡器，一个放后端服务器。这种「按可用区切分」
# 的划法本身就是可用区隔离的地基——每个可用区的资源都落在自己的网段里，
# 故障与撤离的边界因此变得清晰可见。
#
# 子网按用途划分为负载均衡子网与后端子网，均以命名区分，
# 仅在虚拟私有云内部使用，不绑定弹性公网 IP。
# ---------------------------------------------------------------------------

resource "huaweicloud_vpc" "main" {
  name = "${var.name_prefix}-vpc"
  cidr = var.vpc_cidr

  enterprise_project_id = var.enterprise_project_id
  tags                  = local.common_tags
}

# 负载均衡器子网（每可用区一个）
resource "huaweicloud_vpc_subnet" "lb" {
  count = local.az_count

  name              = "${var.name_prefix}-lb-${local.az_suffixes[count.index]}"
  cidr              = local.lb_subnet_cidrs[count.index]
  gateway_ip        = cidrhost(local.lb_subnet_cidrs[count.index], 1)
  vpc_id            = huaweicloud_vpc.main.id
  availability_zone = local.availability_zones[count.index]

  tags = merge(local.common_tags, {
    availability_zone = local.availability_zones[count.index]
    tier              = "loadbalancer"
  })
}

# 后端服务器子网（每可用区一个）
resource "huaweicloud_vpc_subnet" "app" {
  count = local.az_count

  name              = "${var.name_prefix}-app-${local.az_suffixes[count.index]}"
  cidr              = local.app_subnet_cidrs[count.index]
  gateway_ip        = cidrhost(local.app_subnet_cidrs[count.index], 1)
  vpc_id            = huaweicloud_vpc.main.id
  availability_zone = local.availability_zones[count.index]

  tags = merge(local.common_tags, {
    availability_zone = local.availability_zones[count.index]
    tier              = "application"
  })
}

# ---------------------------------------------------------------------------
# 安全组
#
# 只放行两类流量：负载均衡器到后端服务的探测与转发，以及虚拟私有云内部的访问。
# 内网形态下入站规则收敛到虚拟私有云网段，暴露面更小。
# ---------------------------------------------------------------------------

resource "huaweicloud_networking_secgroup" "app" {
  name                 = "${var.name_prefix}-app-sg"
  description          = "Backend web servers"
  delete_default_rules = true
}

resource "huaweicloud_networking_secgroup_rule" "app_in_http" {
  security_group_id = huaweicloud_networking_secgroup.app.id
  description       = "Application traffic and health probes from within the VPC"
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = var.app_port
  port_range_max    = var.app_port
  remote_ip_prefix  = var.vpc_cidr
}

# 负载均衡器的健康检查源地址固定为 100.125.0.0/16，不在虚拟私有云网段内，需单独放行
resource "huaweicloud_networking_secgroup_rule" "app_in_lb_probe" {
  security_group_id = huaweicloud_networking_secgroup.app.id
  description       = "Health probes from the load balancer"
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = var.app_port
  port_range_max    = var.app_port
  remote_ip_prefix  = "100.125.0.0/16"
}

resource "huaweicloud_networking_secgroup_rule" "app_in_ssh" {
  count = var.key_pair_name != "" ? 1 : 0

  security_group_id = huaweicloud_networking_secgroup.app.id
  description       = "SSH from within the VPC"
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = var.vpc_cidr
}

resource "huaweicloud_networking_secgroup_rule" "app_out_all" {
  security_group_id = huaweicloud_networking_secgroup.app.id
  description       = "Allow all egress"
  direction         = "egress"
  ethertype         = "IPv4"
  remote_ip_prefix  = "0.0.0.0/0"
}

# ---------------------------------------------------------------------------
# 公网出口（可选）
#
# 公网网关是虚拟私有云级别的资源，一个即可覆盖全部子网。
#
# 默认整体关闭：后端只用镜像自带的解释器起服务，没有出网需求。
# ---------------------------------------------------------------------------

resource "huaweicloud_vpc_eip" "nat" {
  count = var.enable_nat_gateway ? 1 : 0

  publicip {
    type = "5_bgp"
  }

  bandwidth {
    name        = "${var.name_prefix}-nat-bw"
    size        = 5
    share_type  = "PER"
    charge_mode = "traffic"
  }

  enterprise_project_id = var.enterprise_project_id
  tags                  = local.common_tags
}

resource "huaweicloud_nat_gateway" "main" {
  count = var.enable_nat_gateway ? 1 : 0

  name        = "${var.name_prefix}-nat"
  description = "Shared internet egress for backend servers"
  spec        = var.nat_gateway_spec
  vpc_id      = huaweicloud_vpc.main.id
  subnet_id   = huaweicloud_vpc_subnet.app[0].id

  enterprise_project_id = var.enterprise_project_id
  tags                  = local.common_tags
}

resource "huaweicloud_nat_snat_rule" "app" {
  count = var.enable_nat_gateway ? local.az_count : 0

  nat_gateway_id = huaweicloud_nat_gateway.main[0].id
  subnet_id      = huaweicloud_vpc_subnet.app[count.index].id
  floating_ip_id = huaweicloud_vpc_eip.nat[0].id
}

# ---------------------------------------------------------------------------
# 负载均衡（架构核心）
#
# 整套实践成立与否，取决于这一个约束：**每个负载均衡器只落在一个可用区里**。
#
# 如果一个负载均衡器横跨多个可用区，那么把它从解析里摘掉就等于同时摘掉了多个
# 可用区，「按可用区撤离」也就无从谈起。所以这里为每个可用区建一个独立的
# 负载均衡器，它的 availability_zone 只填一个值，后端池里也只放同一个可用区的
# 服务器——故障域和撤离单元因此严格重合。
#
# 可用区归属由 availability_zone 直接决定，语义由拓扑本身保证。
# ---------------------------------------------------------------------------

# 启用 HTTPS 监听器时才需要七层规格
data "huaweicloud_elb_flavors" "l7" {
  count = var.enable_https_listener ? 1 : 0

  type = "L7_elastic_max"
  name = var.elb_l7_flavor_name
}

locals {
  # 四层监听时负载均衡器直接转发 TCP；启用 HTTPS 时由负载均衡器终结 TLS，
  # 后端改走明文 HTTP。
  listener_protocol = var.enable_https_listener ? "HTTPS" : "TCP"
  pool_protocol     = var.enable_https_listener ? "HTTP" : "TCP"
  listener_port     = var.enable_https_listener ? 443 : var.listener_port
}

resource "huaweicloud_elb_loadbalancer" "per_az" {
  count = local.az_count

  name        = "${var.name_prefix}-elb-${local.az_suffixes[count.index]}"
  description = "Serves traffic for availability zone ${local.availability_zones[count.index]} only"

  # 这一行是可用区隔离的全部要害：只填一个可用区
  availability_zone = [local.availability_zones[count.index]]

  vpc_id          = huaweicloud_vpc.main.id
  ipv4_subnet_id  = huaweicloud_vpc_subnet.lb[count.index].ipv4_subnet_id

  # 规格按名字显式选定，见 main.tf 中数据源处的说明
  l4_flavor_id = data.huaweicloud_elb_flavors.l4.ids[0]
  l7_flavor_id = var.enable_https_listener ? data.huaweicloud_elb_flavors.l7[0].ids[0] : null

  deletion_protection_enable = var.environment == "prod"

  enterprise_project_id = var.enterprise_project_id

  tags = merge(local.common_tags, {
    availability_zone = local.availability_zones[count.index]
    az_suffix         = local.az_suffixes[count.index]
  })

  lifecycle {
    # 数据源按名字过滤后必须唯一命中，否则宁可让 plan 失败，
    # 也不能默默建出一个非预期规格的实例。
    precondition {
      condition     = length(data.huaweicloud_elb_flavors.l4.ids) == 1
      error_message = "四层规格 ${var.elb_l4_flavor_name} 在区域 ${var.region} 未唯一命中（实际命中 ${length(data.huaweicloud_elb_flavors.l4.ids)} 个）。请先用 huaweicloud_elb_flavors 数据源核对该区域的规格目录，不要放任系统代选。"
    }

    precondition {
      condition     = !var.enable_https_listener || var.https_certificate_id != null
      error_message = "启用 HTTPS 监听器时必须提供 https_certificate_id。"
    }
  }
}

# ---------------------------------------------------------------------------
# 监听器
# ---------------------------------------------------------------------------

resource "huaweicloud_elb_listener" "per_az" {
  count = local.az_count

  name            = "${var.name_prefix}-listener-${local.az_suffixes[count.index]}"
  loadbalancer_id = huaweicloud_elb_loadbalancer.per_az[count.index].id
  protocol        = local.listener_protocol
  protocol_port   = local.listener_port

  server_certificate = var.enable_https_listener ? var.https_certificate_id : null

  # 让后端拿到真实客户端地址
  transparent_client_ip_enable = var.enable_https_listener ? null : true

  tags = merge(local.common_tags, {
    az_suffix = local.az_suffixes[count.index]
  })
}

# ---------------------------------------------------------------------------
# 后端服务器组
#
# 每个组只放本可用区的那一台服务器。组与可用区一一对应，是隔离边界的第二道保证。
# ---------------------------------------------------------------------------

resource "huaweicloud_elb_pool" "per_az" {
  count = local.az_count

  name        = "${var.name_prefix}-pool-${local.az_suffixes[count.index]}"
  description = "Backends in availability zone ${local.availability_zones[count.index]}"
  protocol    = local.pool_protocol
  lb_method   = "ROUND_ROBIN"
  listener_id = huaweicloud_elb_listener.per_az[count.index].id

  # 摘除后端时先排空存量连接
  connection_drain_enabled = true
  connection_drain_timeout = var.connection_drain_timeout
}

resource "huaweicloud_elb_member" "web" {
  count = local.az_count

  pool_id       = huaweicloud_elb_pool.per_az[count.index].id
  address       = huaweicloud_compute_instance.web[count.index].access_ip_v4
  protocol_port = var.app_port
  subnet_id     = huaweicloud_vpc_subnet.app[count.index].ipv4_subnet_id
}

# ---------------------------------------------------------------------------
# 后端健康检查
#
# 这一层检查的对象是「某台服务器是否还活着」，与撤离开关无关——撤离是人为的
# 运维决策，健康检查是自动的故障发现，两者各管一段，不要混为一谈。
# ---------------------------------------------------------------------------

resource "huaweicloud_elb_monitor" "per_az" {
  count = local.az_count

  name             = "${var.name_prefix}-monitor-${local.az_suffixes[count.index]}"
  pool_id          = huaweicloud_elb_pool.per_az[count.index].id
  protocol         = "HTTP"
  url_path         = var.health_check_path
  port             = var.app_port
  interval         = var.monitor_interval
  timeout          = var.monitor_timeout
  max_retries      = var.monitor_max_retries
  max_retries_down = var.monitor_max_retries_down
}

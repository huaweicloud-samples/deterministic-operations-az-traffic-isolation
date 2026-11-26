# ---------------------------------------------------------------------------
# 内网域名与解析记录
#
# 域名是这套架构对外的唯一入口，也是撤离动作最终落地的地方。
#
# 用内网域名而不是公网域名，有两个实际考虑：解析范围绑定在虚拟私有云内，
# 不需要备案就能完整验证；同时避免把演示环境暴露到公网。
# ---------------------------------------------------------------------------

resource "huaweicloud_dns_zone" "internal" {
  name        = local.zone_name
  zone_type   = "private"
  email       = var.zone_admin_email
  ttl         = 300
  description = "Internal zone for the availability zone isolation practice"

  router {
    router_id     = huaweicloud_vpc.main.id
    router_region = var.region
  }

  enterprise_project_id = var.enterprise_project_id
  tags                  = local.common_tags
}

# ---------------------------------------------------------------------------
# 应用记录
#
# 一条 A 记录，同时携带三个可用区负载均衡器的地址。客户端解析后在这几个地址
# 之间轮询，流量因此均分。
#
# 撤离一个可用区，就是把它的地址从这个列表里拿掉。
#
# records 被排除在变更检测之外：它的取值由控制面函数在运行期改写，基础设施
# 代码只负责把记录建出来并给一个初始值。若不让出这份所有权，下一次 apply 会
# 悄悄把地址列表恢复成「三个可用区全在」——相当于无声地回滚了一次线上撤离，
# 而且不会报任何错。
# ---------------------------------------------------------------------------

resource "huaweicloud_dns_recordset" "app" {
  zone_id     = huaweicloud_dns_zone.internal.id
  name        = local.app_fqdn
  type        = "A"
  ttl         = var.record_ttl
  records     = [for lb in huaweicloud_elb_loadbalancer.per_az : lb.ipv4_address]
  description = "Serving set of availability zones. Rewritten by the controller at runtime"

  lifecycle {
    ignore_changes = [records]
  }
}

# ---------------------------------------------------------------------------
# 单可用区直连记录
#
# 绕过分流逻辑直接打到某一个可用区，用于确认「某个可用区自己是好的」——
# 排查时能把「可用区故障」和「分流没生效」这两件事区分开。
# 这些记录不参与撤离，始终指向固定地址。
# ---------------------------------------------------------------------------

resource "huaweicloud_dns_recordset" "per_az" {
  count = local.az_count

  zone_id     = huaweicloud_dns_zone.internal.id
  name        = local.per_az_fqdn[count.index]
  type        = "A"
  ttl         = var.record_ttl
  records     = [huaweicloud_elb_loadbalancer.per_az[count.index].ipv4_address]
  description = "Direct entry point for availability zone ${local.availability_zones[count.index]}"
}

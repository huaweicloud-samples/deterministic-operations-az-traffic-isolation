# ---------------------------------------------------------------------------
# 控制面
#
# 解析服务本身不具备「按健康状态自动选路」的能力，因此这份判断与执行由本实践
# 显式建成一个自有控制面：一个函数定时读撤离开关，把结论写进解析记录。
#
# 好处是判定逻辑、反转语义、失败时的行为全部握在自己手里，可读可改可审计；
# 代价是这套东西需要自己维护。
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 运行期身份
#
# 绑定委托后由运行时下发临时凭证供函数使用。
# ---------------------------------------------------------------------------
resource "huaweicloud_identity_agency" "controller" {
  count = var.controller_agency_name == null ? 1 : 0

  name        = "${var.name_prefix}-controller-agency"
  description = "Allows the controller function to read the switch bucket and update DNS records"

  # op_svc_cff 是云服务委托方，服务端读回时落在 delegated_service_name 字段。
  # 若写成 delegated_domain_name，每次 plan 都会出现一条消不掉的差异。
  delegated_service_name = "op_svc_cff"

  # 角色必须按其授权类型放进对应字段，放错位置服务端会接受请求但不生效：
  #   AX 类型（如 OBS Administrator）—— 全局服务授权，放 domain_roles
  #   XA 类型（如 DNS Administrator）—— 项目级授权，放 project_role
  # 判断办法见 docs/troubleshooting；两者填反的表现是委托看似创建成功、
  # 函数运行时却拿不到该权限。
  domain_roles = var.controller_agency_roles

  dynamic "project_role" {
    for_each = length(var.controller_agency_project_roles) > 0 ? [1] : []

    content {
      project = var.region
      roles   = var.controller_agency_project_roles
    }
  }
}

locals {
  controller_agency = coalesce(
    var.controller_agency_name,
    try(huaweicloud_identity_agency.controller[0].name, null),
  )

  # 记录集资源 ID 的形式是 <zone_id>/<recordset_id>，接口只要后半段
  app_recordset_id = element(split("/", huaweicloud_dns_recordset.app.id), 1)

  # 交给函数的可用区清单：每个可用区对应一个标记文件和一个负载均衡器地址
  controller_zone_map = [
    for i, suffix in local.az_suffixes : {
      suffix            = suffix
      availability_zone = local.availability_zones[i]
      evacuation_key    = local.evacuation_keys[suffix]
      address           = huaweicloud_elb_loadbalancer.per_az[i].ipv4_address
    }
  ]
}

# ---------------------------------------------------------------------------
# 控制面函数
#
# 代码内联下发，只用标准库，不需要打包任何第三方依赖。
# ---------------------------------------------------------------------------
resource "huaweicloud_fgs_function" "controller" {
  name        = "${var.name_prefix}-controller"
  app         = "default"
  description = "Reads the evacuation switch and keeps the application record in sync"

  runtime     = var.controller_runtime
  handler     = "index.handler"
  code_type   = "inline"
  func_code   = file("${path.module}/../src/controller/index.py")
  memory_size = 128
  timeout     = 60
  agency      = local.controller_agency

  user_data = jsonencode({
    region       = var.region
    zone_id      = huaweicloud_dns_zone.internal.id
    recordset_id = local.app_recordset_id
    record_name  = local.app_fqdn
    record_ttl   = tostring(var.record_ttl)
    bucket       = huaweicloud_obs_bucket.switch.bucket
    obs_endpoint = "obs.${var.region}.myhuaweicloud.com"
    fail_open    = tostring(var.controller_fail_open)
    zones        = jsonencode(local.controller_zone_map)
  })

  depends_on = [huaweicloud_obs_bucket_policy.switch]
}

# ---------------------------------------------------------------------------
# 定时驱动
#
# 固定频率触发，最小粒度是一分钟——这也是本实践收敛时间的主要来源。
#
# 触发器一旦进入生效状态就拒绝原地更新，所以把它的配置排除在变更检测之外；
# 确需调整周期时先销毁重建。
# ---------------------------------------------------------------------------
resource "huaweicloud_fgs_function_trigger" "controller_timer" {
  function_urn = huaweicloud_fgs_function.controller.urn
  type         = "TIMER"

  event_data = jsonencode({
    name          = "${var.name_prefix}-controller-timer"
    schedule_type = "Rate"
    schedule      = var.controller_schedule
    user_event    = ""
  })

  lifecycle {
    ignore_changes = [event_data, status]
  }
}

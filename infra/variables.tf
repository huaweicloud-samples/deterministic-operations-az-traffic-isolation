# ---------------------------------------------------------------------------
# 输入变量
# ---------------------------------------------------------------------------

# --- 基础 -------------------------------------------------------------------

variable "region" {
  description = "资源所在区域"
  type        = string
  default     = "cn-north-4"
}

variable "name_prefix" {
  description = "资源名前缀，用于统一命名与检索"
  type        = string
  default     = "az-isolation"

  validation {
    condition     = can(regex("^[a-z0-9-]{1,24}$", var.name_prefix))
    error_message = "前缀只允许小写字母、数字与连字符，长度不超过 24。"
  }
}

variable "environment" {
  description = "环境标识，取 prod 时会为负载均衡器开启删除保护"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "环境必须是 dev、staging、prod 之一。"
  }
}

variable "enterprise_project_id" {
  description = "企业项目 ID，留空表示使用默认企业项目"
  type        = string
  default     = null
}

# --- 网络 -------------------------------------------------------------------

variable "vpc_cidr" {
  description = "虚拟私有云网段"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "必须是合法的 IPv4 网段。"
  }
}

variable "enable_nat_gateway" {
  description = <<-EOT
    是否为后端服务器创建公网出口。
    默认关闭：本实践的后端只用镜像自带的 Python 解释器起一个 HTTP 服务，没有出网需求，
    确需在实例上安装软件时再打开。
  EOT
  type        = bool
  default     = false
}

variable "nat_gateway_spec" {
  description = "公网 NAT 网关规格，1 为小型。仅在 enable_nat_gateway 为 true 时生效"
  type        = string
  default     = "1"
}

# --- 后端服务器 -------------------------------------------------------------

variable "image_name_regex" {
  description = "后端服务器使用的公共镜像名，需自带 Python 3"
  type        = string
  default     = "^Ubuntu 22.04 server 64bit$"
}

variable "ecs_flavor_id" {
  description = "后端服务器规格。显式写死，不交给数据源下标或默认值决定"
  type        = string
  default     = "s6.small.1"
}

variable "system_disk_type" {
  description = "系统盘类型。GPSSD 为华为云通用型固态硬盘"
  type        = string
  default     = "GPSSD"
}

variable "system_disk_size" {
  description = "系统盘容量（GB）"
  type        = number
  default     = 40
}

variable "system_disk_kms_key_id" {
  description = <<-EOT
    系统盘加密所用的密钥 ID。留空表示不加密。
    需加密系统盘时显式指定一个密钥，因此这里作为可选项暴露出来。
  EOT
  type        = string
  default     = null
}

variable "key_pair_name" {
  description = "登录密钥对名称，留空表示不配置登录方式"
  type        = string
  default     = ""
}

variable "app_port" {
  description = "后端服务监听端口"
  type        = number
  default     = 8080

  validation {
    condition     = var.app_port > 0 && var.app_port <= 65535
    error_message = "端口必须在 1 到 65535 之间。"
  }
}

variable "health_check_path" {
  description = "后端健康检查路径"
  type        = string
  default     = "/health"
}

# --- 负载均衡 ---------------------------------------------------------------

variable "elb_l4_flavor_name" {
  description = <<-EOT
    负载均衡器的四层规格名。
    L4_flavor.elb.pro.max 是网络型四层的弹性档，也是该档位下唯一的规格。
  EOT
  type        = string
  default     = "L4_flavor.elb.pro.max"
}

variable "listener_port" {
  description = "负载均衡器对外监听端口"
  type        = number
  default     = 80
}

variable "monitor_interval" {
  description = "后端健康检查间隔（秒）"
  type        = number
  default     = 5
}

variable "monitor_timeout" {
  description = "单次健康检查超时（秒）"
  type        = number
  default     = 3
}

variable "monitor_max_retries" {
  description = "连续成功多少次判定后端健康"
  type        = number
  default     = 2
}

variable "monitor_max_retries_down" {
  description = "连续失败多少次判定后端异常"
  type        = number
  default     = 2
}

variable "connection_drain_timeout" {
  description = "后端摘除后的连接排空时长（秒）"
  type        = number
  default     = 30
}

# --- 内网域名 ---------------------------------------------------------------

variable "private_zone_name" {
  description = "内网域名。仅在关联的虚拟私有云内可解析，不需要备案"
  type        = string
  default     = "az-isolation.internal."
}

variable "app_subdomain" {
  description = "应用子域，与内网域名拼成对外提供服务的名字"
  type        = string
  default     = "app"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.app_subdomain))
    error_message = "子域必须是合法的域名标签。"
  }
}

variable "zone_admin_email" {
  description = "内网域名的管理员邮箱"
  type        = string
  default     = "admin@example.com"
}

variable "record_ttl" {
  description = <<-EOT
    应用记录的缓存时长（秒）。
    这个值直接决定撤离动作的收敛速度，取小值。
  EOT
  type        = number
  default     = 5
}

# --- 撤离开关与控制面 -------------------------------------------------------

variable "enable_switch_bucket_versioning" {
  description = <<-EOT
    是否为撤离开关桶开启版本控制。
    默认关闭：版本化的桶在销毁时可能因批量删除对象失败而残留。
    撤离动作的审计留痕已由控制面函数的结构化日志承载。
  EOT
  type        = bool
  default     = false
}

variable "controller_schedule" {
  description = <<-EOT
    控制面轮询周期。固定频率触发器的最小粒度是 1 分钟，
    这也是本实践收敛时间（约 60-70 秒）的主要来源。
  EOT
  type        = string
  default     = "1m"
}

variable "controller_fail_open" {
  description = <<-EOT
    读取撤离开关失败时的行为。
    true  —— 视为「未撤离」，即对象存储不可用不会导致任何可用区被摘除，避免级联故障
    false —— 保持当前解析不变，不做任何改写
  EOT
  type        = bool
  default     = true
}

variable "controller_agency_name" {
  description = "复用已有委托的名称。留空则由本实践自行创建"
  type        = string
  default     = null
}

variable "controller_agency_roles" {
  description = "自建委托的全局服务级（AX 类型）角色。读取撤离开关桶需要 OBS Administrator。注意：项目级（XA 类型）角色放这里不会生效，须改用 controller_agency_project_roles。"
  type        = list(string)
  default     = ["OBS Administrator"]
}

variable "controller_agency_project_roles" {
  description = "自建委托的项目级（XA 类型）角色，授予范围为 var.region 所在项目。改写解析记录需要 DNS Administrator——该角色在华为云是 XA 类型，只能项目级授权。"
  type        = list(string)
  default     = ["DNS Administrator"]
}

variable "controller_domain_id" {
  description = "委托临时凭证归属的 IAM domain ID，用于桶策略 Principal 的 domain/ 前缀。注意不要误取函数 URN（urn:fss:<region>:<project_id>:function:...）中的那一段——那是 project ID 而非 domain ID，填错会导致桶策略不匹配、函数读开关 403。真实 domain ID 可用 IAM 的 auth domains 接口查询。留空则回退到 data.huaweicloud_account.current.id。"
  type        = string
  default     = ""
}

variable "controller_runtime" {
  description = "控制面函数运行时"
  type        = string
  default     = "Python3.10"
}

# --- 可选能力 ---------------------------------------------------------------

variable "enable_https_listener" {
  description = <<-EOT
    是否启用 HTTPS 监听器以在负载均衡器上终结 TLS。
    默认关闭：华为云独享型负载均衡器的四层监听器为 TCP/UDP，终结 TLS 需要七层规格并预先导入证书，
    这与「可用区隔离」这一主题无关。
    打开时必须同时提供 https_certificate_id 与七层规格。
  EOT
  type        = bool
  default     = false
}

variable "https_certificate_id" {
  description = "HTTPS 监听器使用的服务器证书 ID，仅在 enable_https_listener 为 true 时必填"
  type        = string
  default     = null
}

variable "elb_l7_flavor_name" {
  description = "启用 HTTPS 监听器时使用的七层规格名"
  type        = string
  default     = "L7_flavor.elb.pro.max"
}

variable "enable_test_instance" {
  description = <<-EOT
    是否创建一台测试机。
    内网域名只在虚拟私有云内部可解析，需要一台位于同一网络的机器才能验证撤离效果。
  EOT
  type        = bool
  default     = true
}

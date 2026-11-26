# ---------------------------------------------------------------------------
# 可用区隔离实践 —— Provider、数据源与公共取值
#
# 这套实践要解决的问题是：当某个可用区出现异常时，如何用一条命令把流量整体
# 移出该可用区，并在恢复后同样用一条命令让它回到服务中——全程不修改基础设施
# 代码，也不重启任何实例。
#
# 做法是把「哪些可用区在服务中」这件事，从基础设施代码里剥离出来，交给一个
# 对象存储桶承载：桶里有 az-N-evacuate.txt 就表示第 N 个可用区已撤离。一个
# 定时函数负责读这个开关，并把结论写进内网域名的解析记录。
# ---------------------------------------------------------------------------

provider "huaweicloud" {
  region = var.region
}

# ---------------------------------------------------------------------------
# 数据源
# ---------------------------------------------------------------------------

# 可用区列表。本实践固定取前三个，与每可用区一套独立资源一一对应。
data "huaweicloud_availability_zones" "available" {}

# 账号信息。用于拼接对象存储桶策略里的授权主体。
data "huaweicloud_account" "current" {}

# 后端服务器镜像。
data "huaweicloud_images_image" "web" {
  name_regex  = var.image_name_regex
  visibility  = "public"
  most_recent = true
}

# ---------------------------------------------------------------------------
# 负载均衡器规格
#
# 这是需要显式选定的必填决策项，因此按名字选定，绝不用下标去猜。
#
# 选 L4_flavor.elb.pro.max：网络型四层的弹性档，也是该档位
# 下唯一的规格。
#
# 数据源可能因为名字拼错、区域无此规格而返回 0 条，也可能因为过滤条件太松而
# 返回多条——两种情况都会让实际建出的规格脱离预期，所以在使用处加了断言。
# ---------------------------------------------------------------------------
data "huaweicloud_elb_flavors" "l4" {
  type = "L4_elastic_max"
  name = var.elb_l4_flavor_name
}

# ---------------------------------------------------------------------------
# 公共取值
# ---------------------------------------------------------------------------

locals {
  # 固定使用三个可用区，与每可用区一套资源对应
  az_count           = 3
  availability_zones = slice(data.huaweicloud_availability_zones.available.names, 0, local.az_count)

  # 资源名后缀：1 / 2 / 3，用于把每个可用区的资源串起来
  az_suffixes = [for i in range(local.az_count) : tostring(i + 1)]

  # 子网划分：前三段给负载均衡器，后三段给后端服务器
  lb_subnet_cidrs  = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  app_subnet_cidrs = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 4, i + local.az_count)]

  # 内网域名与记录名
  zone_name   = var.private_zone_name
  app_fqdn    = "${var.app_subdomain}.${var.private_zone_name}"
  per_az_fqdn = [for s in local.az_suffixes : "${var.app_subdomain}-az-${s}.${var.private_zone_name}"]

  # 撤离标记文件名。桶里出现哪个文件，就表示哪个可用区被撤离。
  evacuation_keys = { for i, s in local.az_suffixes : s => "az-${s}-evacuate.txt" }

  # 对象存储桶名需全局唯一
  switch_bucket_name = "${var.name_prefix}-az-switch-${random_id.suffix.hex}"

  common_tags = {
    project     = var.name_prefix
    environment = var.environment
    managed_by  = "terraform"
  }
}

resource "random_id" "suffix" {
  byte_length = 4
}

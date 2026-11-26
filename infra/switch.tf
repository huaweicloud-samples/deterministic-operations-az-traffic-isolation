# ---------------------------------------------------------------------------
# 撤离开关
#
# 一个对象存储桶，就是「哪些可用区还在服务中」这件事的唯一真相源。
#
#   桶里有 az-1-evacuate.txt  →  第 1 个可用区已撤离
#   桶里没有这个文件          →  第 1 个可用区正常服务
#
# 注意这里的语义是**反的**：文件存在表示故障而不是健康。这不是绕弯子，而是
# 一个刻意的选择——它让「读不到开关」这件事天然等价于「一切正常」，于是开关
# 本身出问题时不会把整个服务判死。本实践把这条判断显式写在控制面函数里。
#
# 桶默认是空的，也就是默认全部可用区都在服务中。
# ---------------------------------------------------------------------------

resource "huaweicloud_obs_bucket" "switch" {
  bucket = local.switch_bucket_name
  acl    = "private"

  # 版本控制默认关闭：版本化的桶在销毁时可能因批量删除对象失败而残留。
  # 撤离动作的审计留痕由控制面函数的结构化日志承载。
  versioning = var.enable_switch_bucket_versioning

  force_destroy = true

  enterprise_project_id = var.enterprise_project_id
  tags                  = local.common_tags
}

# ---------------------------------------------------------------------------
# 桶策略
#
# 对象存储的数据面不认委托所挂的账号级角色，只认桶策略——只给委托挂上存储管理员
# 角色，函数读对象时照样会被拒。所以这里必须把委托显式写成桶策略的授权主体。
#
# 授权范围也刻意收得很窄：只读，且只限撤离标记文件。桶可以保持私有，暴露面更小。
# ---------------------------------------------------------------------------

# 桶策略授权主体要的是委托临时凭证归属的 IAM domain ID。
# 用 IAM 子用户凭证时它与 data.huaweicloud_account.current.id 可能不同，
# 且不要错取函数 URN 里的那段（那是 project ID），必须用 controller_domain_id 覆盖。
locals {
  controller_principal_domain = (
    var.controller_domain_id != "" ? var.controller_domain_id : data.huaweicloud_account.current.id
  )
}

resource "huaweicloud_obs_bucket_policy" "switch" {
  bucket        = huaweicloud_obs_bucket.switch.bucket
  policy_format = "obs"

  policy = jsonencode({
    Statement = [
      {
        Sid    = "AllowControllerListSwitch"
        Effect = "Allow"
        Principal = {
          ID = ["domain/${local.controller_principal_domain}:agency/${local.controller_agency}"]
        }
        Action   = ["ListBucket"]
        Resource = [huaweicloud_obs_bucket.switch.bucket]
      },
      {
        Sid    = "AllowControllerReadSwitch"
        Effect = "Allow"
        Principal = {
          ID = ["domain/${local.controller_principal_domain}:agency/${local.controller_agency}"]
        }
        Action   = ["GetObject"]
        Resource = ["${huaweicloud_obs_bucket.switch.bucket}/az-*-evacuate.txt"]
      },
    ]
  })
}

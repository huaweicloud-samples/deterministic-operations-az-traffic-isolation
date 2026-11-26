# 本仓库部署用的实际参数（非机密，仅账号相关 ID）
#
# controller_domain_id 必须是 IAM domain ID。容易踩的坑：函数 URN
# urn:fss:cn-north-4:<PROJECT_ID>:function:... 中间那段是 project ID，不是 domain ID。
# 真实 domain ID 由 IAM 的 auth domains 接口查得，或从环境变量注入。
# 填成 project ID 会让桶策略 Principal 不匹配，函数读撤离开关 403，
# 再叠加 fail_open 就表现为「开关放了却不撤离」。
controller_domain_id = "<IAM_DOMAIN_ID>"

# 角色按授权类型分放两个字段，放错位置服务端静默不生效：
#   OBS Administrator = AX（全局服务级）→ controller_agency_roles
#   DNS Administrator = XA（项目级）    → controller_agency_project_roles
# 二者均使用变量默认值，此处无需覆盖。

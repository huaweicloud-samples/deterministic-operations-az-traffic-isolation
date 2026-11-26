# 可用区隔离实践 · 部署指导书

> 本文描述部署、验证与清理步骤，文中凭证一律以占位符表示，请替换为自己的实际值。

## 1. 前置条件

| 项目 | 要求 |
| --- | --- |
| 账号权限 | 具备 VPC、ECS、ELB、DNS、OBS、FunctionGraph、IAM 委托的创建权限 |
| 命令行工具 | Terraform ≥ 1.5.0（本实践使用 `huaweicloud` Provider ≥ 1.60.0） |
| 区域 | 目标区域存在弹性规格 `L4_flavor.elb.pro.max`（部署前用 Provider 数据源核验） |
| 凭证注入 | Provider 凭证通过环境变量 `HW_ACCESS_KEY` / `HW_SECRET_KEY` / `HW_REGION_NAME` 注入，或写入 `~/.huaweicloudrc`，**不要硬编码进 `.tf`** |
| 密钥对（可选） | 如需登录后端排查，提前创建密钥对并填入 `key_pair_name`；不填则不开放 22 端口 |

> 验证区域规格（不需要部署，纯查询）：
> ```hcl
> data "huaweicloud_elb_flavors" "check" {
> type = "L4_elastic_max"
> name = "L4_flavor.elb.pro.max"
> }
> ```
> 若返回 0 条，说明该区域无此弹性规格，需改 `elb_l4_flavor_name` 或换区域。

## 2. 部署步骤

```bash
cd infra

# 1) 初始化（下载 huaweicloud Provider）
terraform init

# 2) 语法与一致性校验
terraform validate

# 3) 预览将创建的资源
terraform plan

# 4) 应用
terraform apply
```

`terraform validate` 通过、`terraform plan` 确认资源无误后，再执行 `terraform apply`。

### 委托授权：角色必须按 AX / XA 类型放进对应字段

这是本实践最容易踩的坑，**放错位置时 `terraform apply` 全绿、控制台也显示委托已创建，但函数运行时拿不到权限**，表现为解析写入 403（`DNS.1802 No permissions for any one of the roles: [dns_adm, ...]`）。

华为云 IAM 角色分两种作用域，取决于角色自身的 `type`：

| 角色 type | 作用域 | 对应字段 | 本实践取值 |
| --- | --- | --- | --- |
| `AX` | 全局服务级 | `domain_roles` | `OBS Administrator` |
| `XA` | 项目级 | `project_role { project, roles }` | `DNS Administrator` |

对应变量为 `controller_agency_roles`（AX）与 `controller_agency_project_roles`（XA），默认值已按上表配好，通常无需改动。若换用其他角色，**先查它的 type 再决定放哪个字段**，不要凭名字猜。

修改委托权限后，函数**必须冷启动**才会拿到带新权限的临时凭证：

```bash
terraform apply -replace=huaweicloud_fgs_function.controller
```

只改函数描述等元数据不会重建运行时，旧凭证会继续被复用。

## 3. 配置撤离开关

部署完成后，`terraform output switch_bucket` 给出撤离开关桶名，`terraform output evacuation_keys` 给出撤离标记文件名（如 `az-1-evacuate.txt`）。

放置/删除标记文件有两种方式（凭据均以占位符表示）：

**方式 A：obsutil 命令行**

```bash
# 一次性配置（凭据以占位符，仅本机生效，不写入任何交付物）
obsutil config -i=<AK> -k=<SK> -e=obs.<REGION>.myhuaweicloud.com

# 撤离第 2 个可用区
obsutil cp ./az-2-evacuate.txt obs://<BUCKET>/az-2-evacuate.txt

# 恢复：删除该标记文件
obsutil rm obs://<BUCKET>/az-2-evacuate.txt
```

**方式 B：控制台**

进入对象存储控制台 → 找到撤离开关桶 → 上传/删除 `az-N-evacuate.txt` 即可，无需任何命令行凭证。

## 4. 验证撤离效果

内网域名只在关联 VPC 内可解析，验证须从同网段的测试机发起：

```bash
# 测试机内网地址见 terraform output tester_private_ip
ssh root@<TESTER_IP>

# 反复请求应用入口，观察返回里的 az_suffix 分布
for i in $(seq 1 20); do
curl -s http://app.az-isolation.internal.:8080/ | python3 -c "import sys,json;print(json.load(sys.stdin)['az_suffix'])"
done
# 正常情况下应在 1/2/3 之间轮询

# 单独确认某个可用区自身健康（绕开分流逻辑）
curl -s http://app-az-2.az-isolation.internal.:8080/ | python3 -c "import sys,json;print(json.load(sys.stdin)['az_name'])"
```

**撤离第 2 个可用区：**

```bash
# 在本地或控制台放入标记文件（见第 3 节）
# 等待 ≤ 1 分钟（定时触发器周期 + 解析 TTL）
sleep 75

# 再次轮询，应只剩 1 和 3
for i in $(seq 1 20); do
curl -s http://app.az-isolation.internal.:8080/ | python3 -c "import sys,json;print(json.load(sys.stdin)['az_suffix'])"
done
```

**恢复：**

```bash
# 删除标记文件
# 等待 ≤ 1 分钟
sleep 75
# 再次轮询，1/2/3 重新出现
```

**控制面日志排查：** `terraform output controller_function_urn` 给出函数 URN，可在函数工作流控制台查看每次执行的日志（含 `changed` / `reason` / `serving` / `evacuated` 字段）。

## 5. 清理资源

```bash
cd infra
terraform destroy
```

清理要点：

- **版本化桶**：若打开了 `enable_switch_bucket_versioning`，先清空桶内所有版本与删除标记，再 `terraform destroy`，否则可能残留资源。
- **0 destroyed ≠ 云端干净**：`terraform destroy` 后，建议通过控制台或 API 直查 ELB / EIP / ECS / 函数是否确有残留。
- **撤离开关文件**：销毁前可保留桶内标记文件用于审计，销毁后一并消失。

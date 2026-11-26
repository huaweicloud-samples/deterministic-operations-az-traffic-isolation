# ---------------------------------------------------------------------------
# 输出
#
# 这里只暴露验证与运维所需的信息。撤离/恢复操作所需的命令示例见
# docs/deployment-guide.md，凭据以占位符表示。
# ---------------------------------------------------------------------------

output "app_fqdn" {
  description = "应用对内服务域名（内网域名，仅关联的虚拟私有云内部可解析）"
  value       = local.app_fqdn
}

output "app_url" {
  description = "应用统一入口地址"
  value       = "http://${local.app_fqdn}:${var.app_port}"
}

output "per_az_urls" {
  description = "各可用区直连入口，用于区分「可用区故障」与「分流未生效」"
  value       = [for fqdn in local.per_az_fqdn : "http://${fqdn}:${var.app_port}"]
}

output "elb_private_ips" {
  description = "各可用区负载均衡器的内网地址，撤离动作最终落地的对象"
  value       = [for lb in huaweicloud_elb_loadbalancer.per_az : lb.ipv4_address]
}

output "vpc_id" {
  description = "虚拟私有云 ID"
  value       = huaweicloud_vpc.main.id
}

output "dns_zone_id" {
  description = "内网域名 ID"
  value       = huaweicloud_dns_zone.internal.id
}

output "switch_bucket" {
  description = "撤离开关桶名；桶内出现 az-N-evacuate.txt 即表示第 N 个可用区已撤离"
  value       = huaweicloud_obs_bucket.switch.bucket
}

output "evacuation_keys" {
  description = "撤离标记文件名清单，与可用区后缀一一对应"
  value       = [for s in local.az_suffixes : local.evacuation_keys[s]]
}

output "controller_function_urn" {
  description = "控制面函数 URN，用于控制台排查或同步调用验证"
  value       = huaweicloud_fgs_function.controller.urn
}

output "controller_timer_name" {
  description = "控制面定时触发器名称"
  value       = jsondecode(huaweicloud_fgs_function_trigger.controller_timer.event_data).name
}

output "tester_private_ip" {
  description = "测试机内网地址，从它发起对内域名的解析与请求以验证撤离效果"
  value       = var.enable_test_instance ? huaweicloud_compute_instance.tester[0].access_ip_v4 : null
}

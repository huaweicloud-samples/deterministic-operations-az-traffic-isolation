# ---------------------------------------------------------------------------
# 后端服务器
#
# 每个可用区一台，各自落在本可用区的子网里。实例上跑的是一个只用标准库写的
# HTTP 服务，会在响应里带上自己所在的可用区编号——验证撤离效果时，靠的就是
# 观察返回内容里可用区编号的分布变化。
# ---------------------------------------------------------------------------

resource "huaweicloud_compute_instance" "web" {
  count = local.az_count

  name              = "${var.name_prefix}-web-${local.az_suffixes[count.index]}"
  image_id          = data.huaweicloud_images_image.web.id
  flavor_id         = var.ecs_flavor_id
  availability_zone = local.availability_zones[count.index]
  security_group_ids = [huaweicloud_networking_secgroup.app.id]
  key_pair          = var.key_pair_name != "" ? var.key_pair_name : null

  system_disk_type       = var.system_disk_type
  system_disk_size       = var.system_disk_size
  system_disk_kms_key_id = var.system_disk_kms_key_id

  user_data = templatefile("${path.module}/../src/userdata/web_server.sh", {
    app_port          = var.app_port
    az_suffix         = local.az_suffixes[count.index]
    az_name           = local.availability_zones[count.index]
    health_check_path = var.health_check_path
  })

  network {
    uuid = huaweicloud_vpc_subnet.app[count.index].id
  }

  enterprise_project_id = var.enterprise_project_id

  tags = merge(local.common_tags, {
    availability_zone = local.availability_zones[count.index]
    az_suffix         = local.az_suffixes[count.index]
    role              = "web-server"
  })

  lifecycle {
    # 镜像会随官方更新滚动，不因此重建实例
    ignore_changes = [image_id]
  }
}

# ---------------------------------------------------------------------------
# 测试机
#
# 内网域名只在虚拟私有云内部可解析，所以验证必须从网络内部发起。
# 这台机器不承载业务，只是一个观察点。
# ---------------------------------------------------------------------------

resource "huaweicloud_compute_instance" "tester" {
  count = var.enable_test_instance ? 1 : 0

  name               = "${var.name_prefix}-tester"
  image_id           = data.huaweicloud_images_image.web.id
  flavor_id          = var.ecs_flavor_id
  availability_zone  = local.availability_zones[0]
  security_group_ids = [huaweicloud_networking_secgroup.app.id]
  key_pair           = var.key_pair_name != "" ? var.key_pair_name : null

  system_disk_type = var.system_disk_type
  system_disk_size = var.system_disk_size

  network {
    uuid = huaweicloud_vpc_subnet.app[0].id
  }

  enterprise_project_id = var.enterprise_project_id

  tags = merge(local.common_tags, {
    role = "tester"
  })

  lifecycle {
    ignore_changes = [image_id]
  }
}

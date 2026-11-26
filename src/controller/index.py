# -*- coding: utf-8 -*-
"""
可用区撤离控制面。

这个函数只做一件事：读撤离开关，然后让应用域名的解析结果与开关保持一致。

开关放在一个对象存储桶里，语义是**反的**——

    桶里有 az-2-evacuate.txt   ->  第 2 个可用区已撤离，把它从解析里摘掉
    桶里没有这个文件           ->  第 2 个可用区正常，留在解析里

之所以用「存在即故障」而不是「存在即健康」，是为了让读不到开关这件事天然
等价于一切正常：开关本身出问题时，不会连锁把整个服务判死。这就是所谓的
fail-open，也是这套设计里最值得保留的一点。

判定与执行都收敛在这里，因此可以清楚地读出三条规则：

  1. 探测不到某个可用区的开关状态时，按「未撤离」处理（fail_open 为 true 时）；
  2. 三个可用区被全部撤离时，不清空解析记录，而是维持原样——把一个域名解析成
     空集合是彻底断服，比任何一个可用区故障都严重；
  3. 解析结果与目标一致时不发起写操作，避免无谓的接口调用与变更记录。

鉴权
  函数绑定委托后由运行时下发临时凭证，代码与函数配置中都不保存任何长期密钥。
  改写解析记录用的是临时令牌；读取对象存储用的是临时访问密钥做请求签名——
  注意这两者是不同的东西，对象存储的数据面不认令牌，也不认委托挂的账号级角色，
  必须由桶策略显式授权。
"""

import base64
import email.utils
import hashlib
import hmac
import json
import urllib.error
import urllib.request

_TIMEOUT = 10


# ---------------------------------------------------------------------------
# 配置与凭证
# ---------------------------------------------------------------------------

def _conf(context, key, default=None):
    """读取函数配置项。这些值由基础设施代码在部署时写入，不硬编码在函数里。"""
    value = context.getUserData(key)
    if value is None or value == "":
        if default is None:
            raise RuntimeError("缺少函数配置项：%s" % key)
        return default
    return value


def _temp_credentials(context):
    """
    取委托下发的临时访问密钥。

    这套凭证只经 context 注入，不进任何环境变量，也不会被 SDK 自动读取。
    """
    ak = context.getSecurityAccessKey()
    sk = context.getSecuritySecretKey()
    token = context.getSecurityToken()
    if not ak or not sk:
        raise RuntimeError("未取得临时访问密钥，请确认函数已绑定委托")
    return ak, sk, token


# ---------------------------------------------------------------------------
# 读撤离开关
# ---------------------------------------------------------------------------

def _sign_v2(method, bucket, key, date, sk, token):
    """
    对象存储的请求签名。

    待签字符串由「方法 + 内容摘要 + 内容类型 + 时间 + 自定义头 + 资源路径」拼成，
    这里只有时间、安全令牌头和资源路径三项有值。
    """
    canonical_headers = "x-obs-security-token:%s\n" % token if token else ""
    canonical_resource = "/%s/%s" % (bucket, key)
    string_to_sign = "%s\n\n\n%s\n%s%s" % (
        method, date, canonical_headers, canonical_resource
    )
    digest = hmac.new(
        sk.encode("utf-8"), string_to_sign.encode("utf-8"), hashlib.sha1
    ).digest()
    return base64.b64encode(digest).decode("utf-8")


def _is_evacuated(bucket, endpoint, key, ak, sk, token):
    """
    探测某个可用区的撤离标记。

    返回 True 表示已撤离，False 表示正常。探测本身失败时抛出异常，由调用方
    按 fail_open 策略决定怎么处理——这里不替上层做决定。
    """
    date = email.utils.formatdate(usegmt=True)
    signature = _sign_v2("HEAD", bucket, key, date, sk, token)

    request = urllib.request.Request(
        url="https://%s.%s/%s" % (bucket, endpoint, key),
        method="HEAD",
    )
    request.add_header("Date", date)
    request.add_header("Authorization", "OBS %s:%s" % (ak, signature))
    if token:
        request.add_header("x-obs-security-token", token)

    try:
        with urllib.request.urlopen(request, timeout=_TIMEOUT):
            # 标记文件存在，该可用区处于撤离状态
            return True
    except urllib.error.HTTPError as error:
        if error.code == 404:
            # 标记文件不存在，该可用区正常服务。这是常态。
            return False
        raise RuntimeError(
            "探测撤离标记 %s 失败，接口返回 %s" % (key, error.code)
        )


# ---------------------------------------------------------------------------
# 改写解析记录
# ---------------------------------------------------------------------------

def _dns_call(method, url, token, body=None):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    request = urllib.request.Request(url=url, data=data, method=method)
    request.add_header("X-Auth-Token", token)
    request.add_header("Content-Type", "application/json")

    try:
        with urllib.request.urlopen(request, timeout=_TIMEOUT) as response:
            payload = response.read().decode("utf-8")
            return json.loads(payload) if payload else {}
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise RuntimeError("解析服务接口返回 %s：%s" % (error.code, detail))


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def handler(event, context):
    region = _conf(context, "region")
    zone_id = _conf(context, "zone_id")
    recordset_id = _conf(context, "recordset_id")
    record_name = _conf(context, "record_name")
    record_ttl = int(_conf(context, "record_ttl", "5"))
    bucket = _conf(context, "bucket")
    obs_endpoint = _conf(context, "obs_endpoint")
    fail_open = _conf(context, "fail_open", "true").lower() == "true"
    zones = json.loads(_conf(context, "zones"))

    ak, sk, security_token = _temp_credentials(context)

    # --- 逐个可用区读开关 ---
    evacuated = []
    serving = []
    probe_errors = []

    for zone in zones:
        try:
            if _is_evacuated(
                bucket, obs_endpoint, zone["evacuation_key"], ak, sk, security_token
            ):
                evacuated.append(zone)
                continue
        except RuntimeError as error:
            probe_errors.append("%s: %s" % (zone["suffix"], error))
            if not fail_open:
                # 读不到开关且不允许乐观放行时，什么都不做，维持现状
                result = {
                    "changed": False,
                    "reason": "probe_failed_fail_closed",
                    "errors": probe_errors,
                }
                print(json.dumps(result, ensure_ascii=False))
                return result
            # 乐观放行：读不到开关就当它没被撤离
        serving.append(zone)

    # --- 兜底：不允许把解析清空 ---
    # 三个可用区全被撤离时，与其把域名解析成空集合造成彻底断服，
    # 不如维持原样，把问题暴露给人来判断。
    if not serving:
        result = {
            "changed": False,
            "reason": "all_zones_evacuated_refusing_empty_record",
            "evacuated": [z["suffix"] for z in evacuated],
        }
        print(json.dumps(result, ensure_ascii=False))
        return result

    desired = sorted(zone["address"] for zone in serving)

    # --- 与当前解析比对，不一致才写 ---
    endpoint = "https://dns.%s.myhuaweicloud.com" % region
    url = "%s/v2/zones/%s/recordsets/%s" % (endpoint, zone_id, recordset_id)

    current = sorted((_dns_call("GET", url, context.getToken()) or {}).get("records") or [])

    if current == desired:
        result = {
            "changed": False,
            "reason": "already_in_sync",
            "serving": [z["suffix"] for z in serving],
            "evacuated": [z["suffix"] for z in evacuated],
            "records": desired,
        }
        print(json.dumps(result, ensure_ascii=False))
        return result

    _dns_call("PUT", url, context.getToken(), {
        "name": record_name,
        "type": "A",
        "ttl": record_ttl,
        "records": desired,
    })

    result = {
        "changed": True,
        "serving": [z["suffix"] for z in serving],
        "evacuated": [z["suffix"] for z in evacuated],
        "records_before": current,
        "records_after": desired,
        "probe_errors": probe_errors,
    }
    print(json.dumps(result, ensure_ascii=False))
    return result

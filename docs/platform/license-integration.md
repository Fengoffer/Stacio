# Stacio License 跨平台接入规范

版本：v1.2
适用客户端：macOS、Windows、Linux
产品：`stacio`

本文是三端共同遵守的授权契约。客户端可以使用原生 UI、更新器和安全存储，但不能改变协议字段、签名语义、设备绑定语义或授权状态机。后台的私钥只存在服务端密钥存储中，任何客户端包都只能包含公开验证材料。

## 1. 目标与不变量

1. 同一设备重启、重打包、覆盖升级、OTA 更新和应用重装后，已保存的有效授权继续可用，不要求用户重复授权。
2. 授权数据不能绑定代码签名、CDHash、构建号、版本号、安装路径或包文件哈希。开发包、正式包和无 Apple 证书的本地测试包必须使用同一授权存储契约。
3. License 校验由底层授权服务统一完成；功能模块只读取内存中的授权快照/entitlement，不在每个功能里发起网络校验。
4. 在线校验失败不覆盖最后一个有效快照；离线授权联网后只能做状态同步，不能因为临时网络错误丢失离线授权。
5. `platform` 只能使用 `macos`、`windows`、`linux`，设备指纹必须包含平台域，不能把不同平台误识别为同一设备。
6. 运行时获取的公钥配置必须按产品、环境/API 地址和配置版本隔离缓存；开发服务器的 key material 不得被正式包复用。

## 2. 在线激活

客户端调用：

```text
POST /api/v1/public/products/{productID}/licenses/validate
```

请求至少包含 `licenseKey`、`username`、`email`、应用版本、构建号和经哈希处理的设备标识。客户端不得把明文设备序列号、私钥、密码或完整诊断内容放入请求。

服务端校验 License 状态、授权版本、有效期、身份和设备风险后返回完整授权结果与服务端签名 token。客户端必须检查：

1. token 版本、签名、`productId`、用户名、邮箱、套餐、entitlements 和有效期。
2. 先校验在线公开配置的 `algorithm`、`signatureKeyID` 和公钥属于客户端信任 key ring；当前在线 `v1` token 本身不携带 `signatureKeyID`，不能把离线授权的字段套到在线 token 上。
3. 服务器返回的 `status` 只能映射到稳定状态机：`active`、`expired`、`suspended`、`revoked`、`invalid`、`networkUnavailable` 等。

在线激活成功后，客户端将完整签名 token 和非秘密展示字段写入平台安全存储，并更新统一 `LicenseAccess` 快照。后续功能只读取该快照。

## 3. 离线设备申请与兑换

### 3.1 设备申请文件

“离线授权”按钮生成稳定设备指纹并导出加密申请文件。设备指纹来源必须通过平台稳定标识组合和不可逆哈希得到，不能依赖临时网络地址、应用安装路径、构建号或随机 UUID。系统重装后仍应通过平台硬件/固件标识恢复同一设备域；若硬件更换导致指纹改变，应显示“设备不匹配”，由管理员执行迁移/重置。

申请文件使用以下 Envelope，文本内容对用户不可解析：

```json
{
  "protocol": "stacio-offline-request",
  "version": 1,
  "keyID": "offline-encryption-2026-01",
  "ephemeralPublicKey": "Base64 raw X25519 public key",
  "nonce": "Base64 12-byte nonce",
  "ciphertext": "Base64 ciphertext plus 16-byte Poly1305 tag"
}
```

密钥协商使用 X25519；派生使用 HKDF-SHA-256，`salt=stacio-offline-request-v1`，`info=stacio:offline-request:v1`；加密使用 12 字节 nonce 的 AEAD。客户端只内置后台 X25519 公钥，不内置私钥。

### 3.2 管理员兑换

管理员向后台提交 `licenseKey`、`username`、`email` 和申请文件。后台验证 License 状态、套餐、有效期、身份和设备绑定，成功后返回 `.stacio-license` 文件。客户端导入时必须验签、验产品、验平台、验设备摘要和有效期，任何一项失败都不得启用功能。

离线授权载荷是规范化、字典序 JSON 的 Ed25519 签名内容，至少包含：

```text
productID, platform, deviceID, username, email, plan,
entitlements, issuedAt, expiresAt, signatureKeyID
```

客户端只保存并显示脱敏后的授权信息；申请文件和授权文件的原始文本不显示在 UI 日志中。旧套餐值 `pro/team/internal` 读取后统一映射为 `professional/professional/enterprise`。

## 4. 在线同步离线授权

设备联网后，用户点击“更新许可”或后台按到期窗口触发状态同步：

```text
POST /api/v1/public/products/{productID}/offline-license/status
```

请求携带当前离线授权的签名内容、设备摘要和请求 ID，不携带也不恢复 License Key。后台严格验签、校验设备绑定及当前 License 状态：

1. `active`/`renewed`：返回新的完整签名授权，客户端原子替换本地快照。
2. `revoked`、`expired`、`deviceMismatch`、`unbound`、`invalidSignature`：返回明确错误码，客户端保留错误原因并按策略禁用授权。
3. 网络超时、DNS 失败或 5xx：保留最后有效离线快照并报告 `networkUnavailable`（在线快照可进入 `offlineGrace`），不能删除授权。

同步不改变离线协议的本地验证路径。用户无感的静默校验窗口为剩余 30、15、3、1 天及已到期时；静默请求失败不应打断正常工作流。

### 4.1 状态同步错误码（跨平台固定）

后台 `error.code` 必须原样保留到共享错误类型，不能只显示本地化 `message`。以下错误是终止类错误，三端处理必须一致：

| 后台错误码 | 客户端持久化状态 | 处理要求 |
| --- | --- | --- |
| `OFFLINE_LICENSE_REVOKED` | `revoked` | 清除离线授权和所有 entitlement；允许用户重新导入新的许可。 |
| `OFFLINE_LICENSE_EXPIRED` | `expired` | 清除离线授权和所有 entitlement；保留到期时间用于展示。 |
| `OFFLINE_DEVICE_MISMATCH` | `invalid` | 清除可用授权；不得在当前设备自动生成新的绑定。 |
| `OFFLINE_BINDING_NOT_FOUND` | `invalid` | 清除可用授权；要求重新导入/重新兑换。 |
| `OFFLINE_AUTHORIZATION_SIGNATURE_INVALID` | `invalid` | 清除可用授权；记录错误码并提示更新或重新兑换。 |

终止类错误必须原子写入 LicenseVault，并保存 `lastAuthorizationSyncErrorCode` 供诊断和 UI 展示。后续启动或网络恢复时不得用仍存在的旧 activation record 自动恢复这份已终止的离线授权；只有用户明确点击“重新导入许可”后才可重新在线激活。未知的 4xx 错误向上抛出，不得改变本地状态。

以下错误属于临时失败：网络断开、超时、DNS 失败、429 和 5xx（包括带未知 `error.code` 的 5xx）。临时失败只能报告 `networkUnavailable` 或把在线快照置为 `offlineGrace`；离线授权继续使用已验签的 `offlineActive` 快照，保留最后有效 entitlement；不得把授权改为 `invalid`，也不得清理 LicenseVault。Windows 和 Linux 必须复用同一错误码枚举和状态转换，平台层只负责安全存储。

## 5. 信任锚与轮换

当前生产公开锚点集中记录在客户端的 `config/license-trust-anchors.json`，Swift/macOS 代码使用同值常量，Windows/Linux 必须生成等价的只读配置：

| 用途 | Key ID | 算法 | 当前公钥 |
| --- | --- | --- | --- |
| 在线授权签名 | `online-license-signing-2026-01` | Ed25519 | `vDKaOq0LGT5s3km7DzuPXxjmJPOnGrXbGRBDrlQ/Glg=` |
| 离线申请加密 | `offline-encryption-2026-01` | X25519 | `EKuNUsbkqkkRJ3B5Q69RQ2UWdjirgMyMKxfB9KO0fFQ=` |
| 离线授权签名 | `offline-signing-2026-01` | Ed25519 | `yGh4lpWhGxrhjFKGBjtNGy1+trm9yOOxwF3+LUmzbWc=` |

生产私钥不能进入 Git、CI 日志、客户端、测试包或文档以外的 artifact。轮换时：

1. 后台先发布新 `keyID` 和公钥，保留旧 key 的验证窗口。
2. 三端先发布包含新旧公钥的 key ring，再由后台切换签发 key。
3. 客户端按 token 的 `keyID` 选择公钥，未知 key 显示不可验证并提示更新，不自动清除现有有效授权。
4. 旧 key 到期后，后台停止签发；客户端在下一个正式版本中移除旧锚点。

## 6. 存储契约与升级

逻辑契约固定为：

```text
contractID: stacio-license-vault-v1
schemaVersion: 1
```

macOS 使用 `~/Library/Application Support/Stacio/LicenseVault/credentials.vault.json` 与 `credentials.vault.key` 的加密 vault，并设置目录 `0700`、文件 `0600`。系统 Keychain 可用时可把密钥材料放入 Keychain，但逻辑 contractID、账户名和迁移语义必须保持不变。

Windows 实现要求：

1. 使用 Windows Credential Manager/DPAPI 保护 vault key，数据文件放在用户级 `%LOCALAPPDATA%\\Stacio\\LicenseVault`。
2. DPAPI scope 固定为当前用户或当前设备，不能随安装包变化；MSIX 升级不得清理该目录。
3. 卸载重装流程必须明确是否保留用户数据；普通覆盖升级和 OTA 必须保留授权 vault。

Linux 实现要求：

1. 首选 Secret Service/libsecret 保存 vault key，数据文件放在 `$XDG_DATA_HOME/stacio/LicenseVault`。
2. Secret Service 不可用时，只能使用权限 `0700/0600` 的加密 vault，并向用户报告存储不可用；禁止降级到明文 JSON、SQLite 或 UserDefaults。
3. Flatpak、`.deb`、`.rpm` 的沙箱/安装脚本都必须验证升级不删除 vault。

所有平台的迁移必须先写新文件、fsync/原子替换、成功后再清理旧数据。读取到旧 schema 时只做向前迁移；迁移失败保留旧数据并进入 `networkUnavailable`/`invalid` 的可诊断状态，不覆盖最后有效快照。

### 6.1 运行时协议配置缓存

离线协议配置（后台 X25519 公钥、离线签名公钥、Key ID 和兑换地址）不是 License 状态本身，必须使用独立的配置缓存。缓存记录至少包含：

```text
productID
apiBaseURL（规范化后的 scheme + host + path）
protocolVersion
requestKeyID / signatureKeyID
public keys
```

客户端读取缓存时必须匹配当前包的产品和 API 地址。旧版本没有作用域字段的缓存只能作为无网络时的诊断数据，不能覆盖正式包内置的信任锚；成功从后台获取新配置后再以原子方式替换缓存。配置缓存损坏或来源不匹配时，回退到包内固定公开锚点，不能把授权状态改为 `invalid`。

## 7. 客户端实现边界

统一提供以下底层接口，功能模块不得直接依赖平台存储或 HTTP：

```text
LicenseActivationService
LicenseStateStore
LicenseVerifier
LicenseAccessSnapshot
LicenseRevalidationCoordinator
```

`LicenseAccessSnapshot` 至少暴露 `status`、`plan`、`entitlements`、`expiresAt`、`source`、`lastValidatedAt` 和可选的 `lastAuthorizationSyncErrorCode`。功能入口只调用 `hasEntitlement("...")` 或读取已发布快照；未授权入口保持灰色不可点击并显示统一提示。客户端启动不应因为网络不可用而强制重新激活。

## 8. 跨平台测试与发布门禁

每个平台至少提供以下自动化测试：

1. 同一 vault 在重启、重新安装同版本、升级版本和 OTA 后仍可读取。
2. 正确签名、错误签名、过期、撤销、设备不匹配、产品不匹配和未知签名 key ID 均得到稳定错误码；在线 token 的 key ID 由公开配置解析。
3. 在线激活成功后断网，所有受限功能仍可按本地快照使用。
4. 离线授权联网同步成功、同步返回撤销/过期、同步 5xx/超时三条路径均不会误清除数据。
5. 离线状态同步的五个固定终止错误码分别落到 `revoked`、`expired` 或 `invalid`，并清空本地 entitlement；未知 4xx 不改变状态。
6. 包后 smoke 校验 Bundle/MSIX/Flatpak 元数据中的公钥、Key ID、`contractID` 和存储标记。
7. 开发 API 地址、正式 API 地址和重打包后的应用不得共享未作用域化的离线协议缓存；切换环境后必须仍能用对应环境的有效授权。
8. 已保存的 `invalid` 状态在新包能够验签时必须先重新评估；网络暂时不可用只能进入 `offlineGrace`/`networkUnavailable`，不能覆盖最后有效快照。

公开测试向量只用于自动化测试，禁止用于生产。测试向量应跨三端共享，并覆盖 `validAuthorization`、`deviceMismatchAuthorization`、`invalidSignatureAuthorization`、`expiredAuthorization`。

发布前必须区分“客户端包构建通过”和“正式授权系统上线”：前者验证包内信任锚及持久化；后者还需要后台公钥、签名私钥、appcast/MSIX/Flatpak 更新源和发行签名均已就绪。

本目录无需任何配置。

- gen.ps1 不读取任何配置文件。首次注册后，key 会自动保存在本机
  ~/.creative-design/license.json，之后不用管它。
- key 丢了或换了电脑：把 sk- 开头那串 key 发给 AI 助手，说「导入这个 key」即可。
- 邮箱已注册、想找回原来的 key：powershell -NoProfile -ExecutionPolicy Bypass -File scripts\gen.ps1 --login 你的邮箱 6位验证码
- 批量出图：powershell -NoProfile -ExecutionPolicy Bypass -File scripts\gen.ps1 --batch 清单.json（UTF-8 JSON 清单，逐张调用同一套命令，失败不中断整批）
- 裁图/放大/白场/拼图（没装 Python 时）：scripts\imgtool.ps1 -Crop|-Zoom|-White|-Sheet
- 查版本：powershell -NoProfile -ExecutionPolicy Bypass -File scripts\gen.ps1 version
- 更新到最新版：powershell -NoProfile -ExecutionPolicy Bypass -File scripts\gen.ps1 update（更新前自动校验 SHA-256，不符会中止；更新后重启一次 opencode）
- 取一次性充值链接（积分不够时）：powershell -NoProfile -ExecutionPolicy Bypass -File scripts\gen.ps1 --pay-link（30 分钟内有效，URL 不含 key，原样发给用户即可）

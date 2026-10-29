本目录无需任何配置。

- gen.cmd 不读取任何配置文件。首次注册后，key 会自动保存在本机
  ~/.creative-design/license.json，之后不用管它。
- key 丢了或换了电脑：把 sk- 开头那串 key 发给 AI 助手，说「导入这个 key」即可。
- 邮箱已注册、想找回原来的 key：scripts\gen.cmd --login 你的邮箱 6位验证码
- 批量出图：scripts\gen.cmd --batch 清单.json（UTF-8 JSON 清单，逐张调用同一套命令，失败不中断整批）
- 裁图/放大/白场/拼图（没装 Python 时）：scripts\imgtool.ps1 -Crop|-Zoom|-White|-Sheet
- 查版本：scripts\gen.cmd version
- 更新到最新版：scripts\gen.cmd update（更新前自动校验 SHA-256，不符会中止；更新后重启一次 opencode）
- 取一次性充值链接（积分不够时）：scripts\gen.cmd --pay-link（30 分钟内有效，URL 不含 key，原样发给用户即可）

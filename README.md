```text
Pebble/
├── TicketApp/                  # App 源码
│   ├── App/                    # 应用入口
│   ├── Features/Receipt/       # 小票界面与状态
│   ├── Domain/                 # 数据规则与校验
│   ├── Pipeline/               # 识别流程
│   ├── Services/               # 底层服务
│   │   ├── OCR/                # 文字识别与布局
│   │   ├── Imaging/            # 图片处理
│   │   └── Inference/          # 本地模型推理
│   ├── Support/Diagnostics/    # 进度与诊断
│   └── Resources/              # 图标与颜色
├── TicketApp.xcodeproj/        # Xcode 工程
├── models/                     # 当前使用的模型
├── Tests/                      # 测试
│   ├── Unit/                   # 单元测试
│   ├── UI/                     # 界面测试
│   └── Regression/             # 命令行回归测试
├── Tools/                      # 开发与测试脚本
├── docs/                       # 需求与开发记录
├── backup/                     # 旧代码、实验及未启用模型
└── AGENT.md                    # 开发协作规范
```

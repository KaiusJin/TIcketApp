```text
Pebble/
├── TicketApp/                  # App 源码
│   ├── App/                    # 应用入口、依赖组装和跨功能导航
│   ├── Features/               # 按用例组织的纵向切片
│   │   ├── Receipt/
│   │   │   ├── Capture/
│   │   │   │   ├── ReceiptCaptureView.swift
│   │   │   │   └── ReceiptCaptureModel.swift
│   │   │   ├── Detail/
│   │   │   │   └── ReceiptDetailView.swift
│   │   │   └── Edit/
│   │   │       └── ReceiptEditorView.swift
│   │   └── Wallet/
│   │       ├── WalletStore.swift
│   │       ├── Home/
│   │       │   └── WalletHomeView.swift
│   │       ├── Drafts/
│   │       │   └── WalletDraftsView.swift
│   │       ├── Statistics/
│   │       │   └── WalletStatisticsView.swift
│   │       └── Settings/
│   │           └── WalletSettingsView.swift
│   ├── Domain/                 # 小票实体、日期、金额与保存规则
│   ├── Pipeline/               # 识别编排与识别结果到领域模型的转换
│   ├── Services/               # 底层服务
│   │   ├── LocalWalletRepository.swift
│   │   ├── WalletPersistence.swift
│   │   ├── OCR/                # 文字识别与布局
│   │   ├── Imaging/            # 图片处理
│   │   └── Inference/          # 本地模型推理
│   ├── UI/                     # 跨切片共用的视觉与格式化代码
│   │   ├── WalletStyle.swift
│   │   ├── WalletComponents.swift
│   │   └── ReceiptPresentation.swift
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

项目按 DDD 的职责边界和 Vertical Slice Architecture 组织，当前仍使用一个 Xcode App target。

- 每个切片收拢自己的页面、状态和用例逻辑。相机包装、骨架屏、编辑行、预算弹窗等专用组件留在所属页面文件；仅在职责和复杂度需要时拆文件，使用具体业务名称。
- `Domain` 保存跨切片共用的实体和业务规则。`SavedReceipt` 负责小票数据及保存条件，识别 JSON 的转换放在 `Pipeline/ReceiptMapping.swift`，金额显示与分类图标放在 `UI/ReceiptPresentation.swift`。
- `WalletStore` 是钱包切片共用的可观察应用状态，协调草稿、确认保存、删除、收藏和预算操作。`Services/LocalWalletRepository.swift` 负责 SwiftData、图片读写、旧数据迁移以及失败回滚；SwiftData 模型集中在 `Services/WalletPersistence.swift`。
- `App` 创建仓储与应用状态并连接页面入口。`Pipeline` 编排识别步骤，`Services` 提供 OCR、图像处理、模型推理和持久化实现。
- `UI` 只放跨切片共享的展示代码，不负责识别或保存流程。普通文案就近定义，颜色和视觉样式集中维护。

小票记录及预算存储在 App 沙盒的 `Library/Application Support/ReceiptWallet/wallet.store`，由 SwiftData 管理，关闭 CloudKit 同步。原图仍是同目录的 `<小票 ID>-<UUID>.image` 文件，通过记录中的 `imageFilename` 关联。首次打开新版时导入旧 `wallet.json`，旧记录按 `Completed` 处理；导入记录和迁移标记一起提交成功后才清理旧 JSON，原图路径保持不变。

拍摄或导入后，先写入原图并创建 `Processing` 草稿，再排队识别。完成识别后写入结构化数据、识别 JSON 和 OCR 文本，状态变为 `Needs review`。核对过程中的有效编辑在离开编辑页或切后台时保留为草稿，点击 Save 才变为 `Completed`。未完成记录统一出现在设置按钮旁的草稿箱中，钱包和统计只读取 `Completed`。

识别队列由 App 持有，关闭拍摄页不会取消任务；推理保留现有 GPU 配置，不增加 CPU 回退或系统持续后台任务。离开前台时取消当前 OCR/推理并保留待处理状态。下次启动或回到前台时，按创建时间先处理未完成、失败的草稿，再处理新记录；失败草稿每次进入前台最多自动尝试一次。已识别完成的草稿只等待核对；主动取消的草稿需在草稿箱手动重试。队列串行处理；取消后等待当前任务退出，再开始下一张小票。

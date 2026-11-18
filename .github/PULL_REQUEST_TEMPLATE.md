## 贡献流程

感谢你参与。这个项目的价值建立在**结论可信**之上 —— 贡献不只是加功能，更重要的是提高证据强度或降低误判。

### 快速开始

```bash
git clone https://github.com/yanyan2015/defect-resolution.git
cd defect-resolution
bash test/run-tests.sh
```

### 提交 PR 前

- [ ] `bash test/run-tests.sh` 全部通过
- [ ] 涉及取证逻辑的改动，附上了「改之前漏了 / 误判了」的具体例子
- [ ] 新增/修改的取证逻辑有对应的回归测试场景
- [ ] PR 描述说清了动机，而不是只说改了什么
- [ ] 一个 PR 一件事；没有混入格式化或无关改动
- [ ] commit message 遵循 Conventional Commits

### 设计相关

改动证据权重、判据或流程前，请先读 [DESIGN.md](DESIGN.md)。其中「核心矛盾」和「已知技术债」两节尤其重要 —— 技术债那一节列出的每一条都是已知且被接受的状态，欢迎直接接手。

如果你的改动较大（新增通道、改权重表、重构脚本），**请先开 issue 对齐设计**，避免 PR 被拒在设计层面。

### 代码风格

- Shell：变量小写 + 下划线；引用变量加双引号；`bash -n` 必须通过
- **注意 `set -e` 陷阱**：管道消费者函数的最后一个命令返回非 0 会直接杀死脚本。新写的函数请显式 `return 0`
- Python：标准库 only，不引入第三方依赖
- 注释写"为什么"，不写"是什么"

### AI 辅助

欢迎使用 AI 辅助开发。PR 作者对代码负责，AI 生成的代码与人工代码承担同样的评审标准。

涉及取证逻辑的改动，**必须**由人实际跑过完整流程并检查输出 —— 取证脚本的错误往往不报错，而是安静地给出错误结论。

### License

提交即表示你同意你的贡献以 [MIT License](LICENSE) 发布。

---

详细说明见 [CONTRIBUTING.md](CONTRIBUTING.md)。

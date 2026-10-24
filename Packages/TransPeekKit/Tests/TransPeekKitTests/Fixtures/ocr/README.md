# OCR 样例库

每个场景一个目录：`<场景名>/image.png` + `expected.json`，格式见 `.kiro/specs/transpeek-mvp/design.md`「集成测试」。

含他人信息（玩家名字、聊天内容）的真实截图只保存在本地，不提交到仓库（`.gitignore` 中按目录排除）。没有本地样例时，OCR 样例库和流水线集成测试会跳过。

可以提交的样例：自己制作的、不含他人信息的截图。

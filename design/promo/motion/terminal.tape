# 段2：终端收到投送（zle widget 模拟 bracketed paste 整段浮现）
Output design/promo/motion/terminal.mp4

Set Width 1200
Set Height 760
Set FontSize 20
Set Padding 40
Set Shell zsh
Set Theme { "background": "#f4f1ea", "foreground": "#393630", "cursor": "#171512", "selection": "#e4dfd2", "black": "#171512", "red": "#9f3f38", "green": "#55805f", "yellow": "#a87f2e", "blue": "#4a6b8a", "magenta": "#7a76b3", "cyan": "#3f8a82", "white": "#f4f1ea", "brightBlack": "#7b7469", "brightRed": "#9f3f38", "brightGreen": "#55805f", "brightYellow": "#a87f2e", "brightBlue": "#4a6b8a", "brightMagenta": "#7a76b3", "brightCyan": "#3f8a82", "brightWhite": "#fffefa" }

Hide
Type "demo-paste() { LBUFFER+=$'## 评审要求\n\n请评审当前 diff，重点检查：\n\n- 竞态：共享状态是否有同步保护\n- 错误路径：IO / IPC 失败会不会静默吞错\n- 死代码：这次改动是否留下失效分支\n\n结论按「必须修 / 建议改 / 可以过」分级，每条给出文件与行号。' }; zle -N demo-paste; bindkey '^P' demo-paste; export PROMPT='%F{green}❯%f '"
Enter
Sleep 500ms
Type "clear"
Enter
Sleep 500ms
Show

Sleep 1500ms
Ctrl+P
Sleep 4s

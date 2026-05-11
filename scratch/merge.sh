#!/bin/bash
TARGET="ChatBot/ChatViewModel.swift"
FILES=("ChatViewModel+API.swift" "ChatViewModel+Agents.swift" "ChatViewModel+Core.swift" "ChatViewModel+Course.swift" "ChatViewModel+Engine.swift" "ChatViewModel+Initialization.swift" "ChatViewModel+MultiAgent.swift" "ChatViewModel+Orchestration.swift" "ChatViewModel+Providers.swift" "ChatViewModel+Schedule.swift" "ChatViewModel+Skills.swift")

for f in "${FILES[@]}"; do
    if [ -f "ChatBot/$f" ]; then
        echo -e "\n\n// --- Merged from $f ---\n" >> "$TARGET"
        grep -v "^import " "ChatBot/$f" >> "$TARGET"
    fi
done

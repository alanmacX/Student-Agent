import os

path = "ChatBot"
main_file = os.path.join(path, "ChatViewModel.swift")

extensions = [
    "ChatViewModel+API.swift",
    "ChatViewModel+Agents.swift",
    "ChatViewModel+Core.swift",
    "ChatViewModel+Course.swift",
    "ChatViewModel+Engine.swift",
    "ChatViewModel+Initialization.swift",
    "ChatViewModel+MultiAgent.swift",
    "ChatViewModel+Orchestration.swift",
    "ChatViewModel+Providers.swift",
    "ChatViewModel+Schedule.swift",
    "ChatViewModel+Skills.swift"
]

with open(main_file, "a") as f:
    for ext in extensions:
        ext_path = os.path.join(path, ext)
        if os.path.exists(ext_path):
            f.write("\n\n// --- Merged from " + ext + " ---\n\n")
            with open(ext_path, "r") as ef:
                lines = ef.readlines()
                for line in lines:
                    if not line.strip().startswith("import "):
                        f.write(line)
        else:
            print(f"Warning: {ext} not found")

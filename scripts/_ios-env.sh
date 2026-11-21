# Shared iOS settings. Override with env vars, e.g. SIMULATOR="iPhone 17" OS=27.0
SIMULATOR="${SIMULATOR:-iPhone 17 Pro}"
OS="${OS:-latest}"
DESTINATION="platform=iOS Simulator,name=$SIMULATOR,OS=$OS"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

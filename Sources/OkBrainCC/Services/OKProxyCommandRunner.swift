import Foundation

enum OKProxyCommandRunner {
  static func installNodeJS(
    forceUpdate: Bool = false,
    onOutput: @escaping @Sendable (String) -> Void
  ) async throws -> OKProxyCommandResult {
    let forceUpdateFlag = forceUpdate ? "1" : "0"
    let command = #"""
set -eo pipefail

LOCAL_NODE="$HOME/.local/bin/node"
FORCE_UPDATE="__FORCE_UPDATE__"

if [ "$FORCE_UPDATE" != "1" ] && [ -x "$LOCAL_NODE" ]; then
  CURRENT_VERSION=$("$LOCAL_NODE" -v)
  CURRENT_MAJOR=$(echo "$CURRENT_VERSION" | sed -E 's/^v([0-9]+).*/\1/')
  if [ -n "$CURRENT_MAJOR" ] && [ "$CURRENT_MAJOR" -ge 20 ]; then
    echo "Node.js is already installed: $CURRENT_VERSION at $LOCAL_NODE"
    exit 0
  fi
fi

if [ "$FORCE_UPDATE" = "1" ]; then
  if [ -x "$LOCAL_NODE" ]; then
    echo "Updating Node.js from $("$LOCAL_NODE" -v) at $LOCAL_NODE..."
  else
    echo "Installing latest Node.js into $HOME/.local..."
  fi
fi

ARCH=$(uname -m)
case "$ARCH" in
  arm64)
    NODE_ARCH="darwin-arm64"
    ;;
  x86_64)
    NODE_ARCH="darwin-x64"
    ;;
  *)
    echo "Error: Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

LTS_DATA=$(curl -fsSL https://nodejs.org/dist/index.json 2>/dev/null | head -c 20000 || true)
TARGET_VERSION=$(printf '%s' "$LTS_DATA" | grep -oE '\{"version":"v[0-9]+\.[^}]*"lts":"[^"]+"[^}]*\}' | head -1 | sed -E 's/.*"version":"(v[0-9]+)\..*/\1/' || true)

if [ -z "$TARGET_VERSION" ]; then
  TARGET_VERSION="v22"
  echo "Could not detect latest LTS. Falling back to Node.js $TARGET_VERSION.x"
else
  echo "Latest LTS detected: Node.js $TARGET_VERSION.x"
fi

NODE_VERSION_FULL=$(curl -fsSL "https://nodejs.org/dist/latest-${TARGET_VERSION}.x/" 2>/dev/null | grep -oE "node-${TARGET_VERSION}\.[0-9]+\.[0-9]+-${NODE_ARCH}\.tar\.gz" | head -1 | sed "s/node-//;s/-${NODE_ARCH}\.tar\.gz//" || true)

if [ -z "$NODE_VERSION_FULL" ]; then
  echo "Error: Could not resolve the latest Node.js $TARGET_VERSION.x download."
  exit 1
fi

NODE_TARBALL="node-${NODE_VERSION_FULL}-${NODE_ARCH}.tar.gz"
NODE_URL="https://nodejs.org/dist/${NODE_VERSION_FULL}/${NODE_TARBALL}"
SHASUMS_URL="https://nodejs.org/dist/${NODE_VERSION_FULL}/SHASUMS256.txt"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "Downloading Node.js ${NODE_VERSION_FULL} for ${ARCH}..."
curl -fsSL "$NODE_URL" -o "$TEMP_DIR/$NODE_TARBALL"
curl -fsSL "$SHASUMS_URL" -o "$TEMP_DIR/SHASUMS256.txt"

echo "Verifying SHA256 checksum..."
EXPECTED_HASH=$(grep "$NODE_TARBALL" "$TEMP_DIR/SHASUMS256.txt" | awk '{print $1}')
ACTUAL_HASH=$(shasum -a 256 "$TEMP_DIR/$NODE_TARBALL" | awk '{print $1}')

if [ -z "$EXPECTED_HASH" ] || [ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]; then
  echo "Error: SHA256 checksum verification failed."
  exit 1
fi

mkdir -p "$HOME/.local"
rm -rf \
  "$HOME/.local/bin/node" \
  "$HOME/.local/bin/npm" \
  "$HOME/.local/bin/npx" \
  "$HOME/.local/bin/corepack" \
  "$HOME/.local/include/node" \
  "$HOME/.local/lib/node" \
  "$HOME/.local/lib/node_modules/npm" \
  "$HOME/.local/lib/node_modules/corepack" \
  "$HOME/.local/share/doc/node" \
  "$HOME/.local/share/man/man1/node.1" \
  2>/dev/null || true

echo "Installing Node.js into $HOME/.local..."
tar -xz -C "$HOME/.local" --strip-components=1 -f "$TEMP_DIR/$NODE_TARBALL"

if [ ! -x "$LOCAL_NODE" ]; then
  echo "Error: Node.js installation failed."
  exit 1
fi

echo "Node.js installed successfully: $("$LOCAL_NODE" -v)"
echo "npm version: $("$HOME/.local/bin/npm" -v)"
"""#

    return try await runShell(
      command.replacingOccurrences(of: "__FORCE_UPDATE__", with: forceUpdateFlag),
      currentDirectory: nil,
      onOutput: onOutput
    )
  }

  static func downloadAndSetup(
    onOutput: @escaping @Sendable (String) -> Void
  ) async throws -> OKProxyCommandResult {
    let installURL = OKProxySettings.installURL
    let capture = OKProxyOutputCapture()
    let relay: @Sendable (String) -> Void = { text in
      capture.append(text)
      onOutput(text)
    }

    try FileManager.default.createDirectory(
      at: installURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    if FileManager.default.fileExists(atPath: installURL.appendingPathComponent(".git", isDirectory: true).path) {
      relay("[OKProxy] Repository already installed at \(installURL.path). Updating instead...\n")
      let result = try await update(onOutput: relay)
      return OKProxyCommandResult(exitCode: result.exitCode, output: capture.value)
    }

    if FileManager.default.fileExists(atPath: installURL.path) {
      let entries = (try? FileManager.default.contentsOfDirectory(atPath: installURL.path)) ?? []
      if entries.isEmpty {
        try FileManager.default.removeItem(at: installURL)
      } else {
        throw OKProxyCommandError.launchFailed(
          "A non-git directory already exists at \(installURL.path). Move it before setup."
        )
      }
    }

    relay("[OKProxy] Cloning \(OKProxySettings.repoURL) into \(installURL.path)...\n")
    let cloneResult = try await runShell(
      "git clone \(shellQuote(OKProxySettings.repoURL)) \(shellQuote(installURL.path))",
      currentDirectory: nil,
      onOutput: relay
    )
    if cloneResult.exitCode != 0 {
      return OKProxyCommandResult(exitCode: cloneResult.exitCode, output: capture.value)
    }

    let setupResult = try await runRepositorySetup(at: installURL, onOutput: relay)
    return OKProxyCommandResult(exitCode: setupResult.exitCode, output: capture.value)
  }

  static func update(
    onOutput: @escaping @Sendable (String) -> Void
  ) async throws -> OKProxyCommandResult {
    let installURL = OKProxySettings.installURL
    guard FileManager.default.fileExists(atPath: installURL.appendingPathComponent(".git", isDirectory: true).path) else {
      throw OKProxyCommandError.missingRepository(installURL.path)
    }

    let capture = OKProxyOutputCapture()
    let relay: @Sendable (String) -> Void = { text in
      capture.append(text)
      onOutput(text)
    }

    relay("[OKProxy] Updating repository at \(installURL.path)...\n")
    let updateResult = try await runShell(
      "git fetch origin && git reset --hard origin/main",
      currentDirectory: installURL,
      onOutput: relay
    )
    if updateResult.exitCode != 0 {
      return OKProxyCommandResult(exitCode: updateResult.exitCode, output: capture.value)
    }

    let setupResult = try await runRepositorySetup(at: installURL, onOutput: relay)
    return OKProxyCommandResult(exitCode: setupResult.exitCode, output: capture.value)
  }

  static func runShell(
    _ command: String,
    currentDirectory: URL?,
    environment extraEnvironment: [String: String] = [:],
    onOutput: @escaping @Sendable (String) -> Void
  ) async throws -> OKProxyCommandResult {
    try await withCheckedThrowingContinuation { continuation in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/bash")
      process.arguments = ["-lc", command]
      process.currentDirectoryURL = currentDirectory

      var environment = ProcessInfo.processInfo.environment
      let localBinPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin", isDirectory: true)
        .path
      environment["PATH"] = "\(localBinPath):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
      for (key, value) in extraEnvironment where !value.isEmpty {
        environment[key] = value
      }
      process.environment = environment

      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = pipe

      let capture = OKProxyOutputCapture()

      pipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else {
          return
        }

        let text = String(decoding: data, as: UTF8.self)
        capture.append(text)
        onOutput(text)
      }

      process.terminationHandler = { process in
        pipe.fileHandleForReading.readabilityHandler = nil
        let remainingData = pipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingData.isEmpty {
          let text = String(decoding: remainingData, as: UTF8.self)
          capture.append(text)
          onOutput(text)
        }

        continuation.resume(
          returning: OKProxyCommandResult(
            exitCode: process.terminationStatus,
            output: capture.value
          )
        )
      }

      do {
        try process.run()
      } catch {
        pipe.fileHandleForReading.readabilityHandler = nil
        continuation.resume(throwing: OKProxyCommandError.launchFailed(error.localizedDescription))
      }
    }
  }

  static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private static func runRepositorySetup(
    at installURL: URL,
    onOutput: @escaping @Sendable (String) -> Void
  ) async throws -> OKProxyCommandResult {
    let packageJSONURL = installURL.appendingPathComponent("package.json")
    guard FileManager.default.fileExists(atPath: packageJSONURL.path) else {
      onOutput("[OKProxy] Repository cloned. No package.json found; setup complete.\n")
      return OKProxyCommandResult(exitCode: 0, output: "")
    }

    onOutput("[OKProxy] Installing Node dependencies...\n")
    return try await runShell(
      "npm install --omit=dev --no-audit --no-fund",
      currentDirectory: installURL,
      onOutput: onOutput
    )
  }
}

final class OKProxyOutputCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = ""
  private let maximumLength = 120_000

  var value: String {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func append(_ text: String) {
    lock.lock()
    storage.append(text)
    if storage.count > maximumLength {
      storage.removeFirst(storage.count - maximumLength)
    }
    lock.unlock()
  }
}

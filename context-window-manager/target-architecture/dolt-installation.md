# Dolt Installation & Server Management

## Design Principle: Invisible Infrastructure

Dolt should be as invisible as SQLite is today. Users don't think about
SQLite — it just works. Dolt should be the same: auto-installed, auto-started,
auto-managed. Power users CAN use `dolt` CLI to inspect, but it's never required.

## Lessons from Prior Dolt Deployments

| Lesson | Impact on Design |
|--------|-----------------|
| Manual `dolt sql-server` after every reboot | Auto-start with process manager |
| 6 separate processes for 3 repos | Single shared server, per-project databases |
| CGO_ENABLED=0 build failures | Dolt binary is pre-built Go, no CGO in Kilo |
| DOLT_ROOT_PASSWORD enables auth when set | Default: no auth (local-only), opt-in auth |
| Stale LOCK files after kill -9 | Health check + recovery on startup |
| 130MB RSS per Dolt process | Single server = one 130MB process, not per-project |
| Noms journal grows to 500MB+ | Periodic GC, data dir monitoring |

## Existing Kilo Pattern: Binary Discovery + Auto-Download

Kilo already auto-downloads binaries for LSP servers (`lsp/server.ts`):

```typescript
// Pattern from lsp/server.ts:123-148 (Vue server example)
let binary = Bun.which("vue-language-server")
if (!binary) {
  if (Flag.KILO_DISABLE_LSP_DOWNLOAD) return
  await Bun.spawn(["bun", "install", "@vue/language-server"], {
    cwd: Global.Path.bin,
  }).exited
}
```

We extend this pattern for Dolt: detect → download → manage.

## Installation Flow

### First Use Detection

```typescript
// storage/dolt/install.ts

export namespace DoltInstall {

  // Resolution order (first match wins)
  export async function resolve(): Promise<DoltBinary | null> {
    // 1. User-configured path (explicit override)
    const configPath = await Config.get().then(c => c.storage?.dolt?.binaryPath)
    if (configPath && await exists(configPath)) {
      return { path: configPath, source: "config", version: await getVersion(configPath) }
    }

    // 2. Kilo-managed binary (auto-downloaded)
    const managedPath = path.join(Global.Path.bin, "dolt")
    if (await exists(managedPath)) {
      return { path: managedPath, source: "managed", version: await getVersion(managedPath) }
    }

    // 3. System PATH (user installed via brew, curl, etc.)
    const systemPath = Bun.which("dolt")
    if (systemPath) {
      return { path: systemPath, source: "system", version: await getVersion(systemPath) }
    }

    // Not found
    return null
  }

  // Auto-download if not found and not disabled
  export async function ensure(): Promise<DoltBinary> {
    const existing = await resolve()
    if (existing) {
      // Version check
      if (existing.version && semver.lt(existing.version, MIN_DOLT_VERSION)) {
        log.warn("dolt version too old", {
          found: existing.version,
          required: MIN_DOLT_VERSION,
          path: existing.path,
        })
        // Don't auto-upgrade system installs — just warn
        if (existing.source === "system") return existing
        // Auto-upgrade managed installs
        return download()
      }
      return existing
    }

    // Not found — auto-download unless disabled
    if (Flag.KILO_DISABLE_DOLT_DOWNLOAD) {
      throw new DoltNotFoundError(
        "Dolt is required for the configured storage backend. " +
        "Install: brew install dolt"
      )
    }

    return download()
  }
}
```

### Auto-Download

```typescript
// storage/dolt/install.ts (continued)

const MIN_DOLT_VERSION = "1.82.0"

// Platform detection (same as Dolt's release naming)
function platform(): string {
  const os = process.platform === "darwin" ? "darwin" : "linux"
  const arch = process.arch === "arm64" ? "arm64" : "amd64"
  return `${os}-${arch}`
}

async function download(): Promise<DoltBinary> {
  const plat = platform()
  const targetDir = Global.Path.bin   // ~/.local/share/kilo/bin/

  log.info("downloading dolt", { platform: plat, target: targetDir })

  // 1. Get latest release URL
  const releaseUrl = `https://github.com/dolthub/dolt/releases/latest/download/dolt-${plat}.tar.gz`

  // 2. Download to temp, extract
  const tempDir = await Filesystem.mkdtemp("dolt-download-")
  const tarball = path.join(tempDir, "dolt.tar.gz")

  await Bun.spawn(["curl", "-fsSL", "-o", tarball, releaseUrl], {
    stdout: "pipe",
    stderr: "pipe",
  }).exited

  await Bun.spawn(["tar", "xzf", tarball, "-C", tempDir], {
    stdout: "pipe",
    stderr: "pipe",
  }).exited

  // 3. Move binary to managed location
  const extractedBin = path.join(tempDir, `dolt-${plat}`, "bin", "dolt")
  const targetBin = path.join(targetDir, "dolt")

  await Filesystem.mkdir(targetDir, { recursive: true })
  await Filesystem.rename(extractedBin, targetBin)
  await Filesystem.chmod(targetBin, 0o755)

  // 4. Cleanup
  await Filesystem.rm(tempDir, { recursive: true })

  const version = await getVersion(targetBin)
  log.info("dolt installed", { version, path: targetBin })

  return { path: targetBin, source: "managed", version }
}
```

### Windows Support

```typescript
async function downloadWindows(): Promise<DoltBinary> {
  const targetDir = Global.Path.bin
  const zipUrl = `https://github.com/dolthub/dolt/releases/latest/download/dolt-windows-amd64.zip`

  // Use PowerShell for download + extract (no curl/tar dependency)
  await Bun.spawn([
    "powershell", "-Command",
    `Invoke-WebRequest -Uri '${zipUrl}' -OutFile '$env:TEMP\\dolt.zip'; ` +
    `Expand-Archive -Path '$env:TEMP\\dolt.zip' -DestinationPath '${targetDir}' -Force`
  ]).exited

  return { path: path.join(targetDir, "dolt.exe"), source: "managed" }
}
```

## Server Management

### The Core Problem

Dolt always runs as a separate process (`dolt sql-server`). There is NO embedded
mode. This means Kilo must:

1. Start a Dolt server when needed
2. Keep it running across sessions
3. Handle crashes and restarts
4. Avoid port conflicts with other Dolt instances
5. Clean up when Kilo is uninstalled

### Port Allocation Strategy

**The problem**: A user might already have Dolt servers running:
- Other Dolt servers may be running on nearby ports
- Or any other service on common ports

**The solution**: Dynamic port allocation with preference list.

```typescript
// storage/dolt/server.ts

const PORT_PREFERENCES = [3307, 3320, 3321, 3322, 3323]

export namespace DoltServer {

  async function findAvailablePort(): Promise<number> {
    // 1. Check if we have a previously allocated port
    const savedPort = await readPortFile()
    if (savedPort && await isPortAvailable(savedPort)) {
      return savedPort
    }
    if (savedPort && await isOurServer(savedPort)) {
      return savedPort  // Our server is already running on this port
    }

    // 2. Try preference list
    for (const port of PORT_PREFERENCES) {
      if (await isPortAvailable(port)) {
        await savePortFile(port)
        return port
      }
    }

    // 3. Fall back to OS-assigned port
    const port = await getRandomAvailablePort()
    await savePortFile(port)
    return port
  }

  async function isOurServer(port: number): Promise<boolean> {
    try {
      // Connect and check the Dolt server identity
      const conn = await mysql2.createConnection({
        host: "127.0.0.1",
        port,
        user: "root",
      })
      const [rows] = await conn.query("SELECT @@kilo_server_id")
      await conn.end()
      return rows[0]?.["@@kilo_server_id"] === getServerID()
    } catch {
      return false
    }
  }

  // Port file: persists the allocated port across sessions
  function portFilePath(): string {
    return path.join(Global.Path.data, "dolt", ".port")
  }
}
```

**Port file**: `~/.local/share/kilo/dolt/.port` stores the dynamically allocated port.
All Kilo processes read this file to find the server. This avoids hardcoding a port
that might conflict with the user's existing setup.

**ADR candidate**: Port allocation strategy deserves formal decision documentation.

### Server Lifecycle

```typescript
// storage/dolt/server.ts

export namespace DoltServer {

  interface ServerState {
    pid: number
    port: number
    dataDir: string
    startedAt: number
    version: string
  }

  // Start the Dolt server (idempotent — no-op if already running)
  export async function start(): Promise<ServerState> {
    // 1. Check if already running
    const existing = await getRunningServer()
    if (existing) {
      log.info("dolt server already running", { pid: existing.pid, port: existing.port })
      return existing
    }

    // 2. Resolve binary
    const binary = await DoltInstall.ensure()

    // 3. Find available port
    const port = await findAvailablePort()

    // 4. Initialize data directory if needed
    const dataDir = path.join(Global.Path.data, "dolt")
    await initDataDir(dataDir, binary)

    // 5. Recover from stale lock files
    await recoverLockFiles(dataDir)

    // 6. Start server process
    const proc = Bun.spawn([
      binary.path, "sql-server",
      "--host", "127.0.0.1",
      "--port", String(port),
      "--data-dir", dataDir,
      "--max-connections", "50",
      "--query-parallelism", "4",
      "--log-level", "warn",
    ], {
      stdout: "pipe",
      stderr: "pipe",
      stdin: "pipe",
      env: {
        ...process.env,
        // No DOLT_ROOT_PASSWORD by default (local-only, no auth)
        // Users can set this for team servers
      },
    })

    // 7. Wait for ready
    await waitForReady(port, 10_000)  // 10s timeout

    // 8. Initialize kilo_meta database
    await initMetaDatabase(port)

    // 9. Persist state
    const state: ServerState = {
      pid: proc.pid,
      port,
      dataDir,
      startedAt: Date.now(),
      version: binary.version!,
    }
    await saveServerState(state)

    log.info("dolt server started", state)
    return state
  }

  // Stop the server gracefully
  export async function stop(): Promise<void> {
    const state = await loadServerState()
    if (!state) return

    try {
      process.kill(state.pid, "SIGTERM")
      // Wait up to 5s for graceful shutdown
      await waitForExit(state.pid, 5_000)
    } catch {
      // Force kill if graceful fails
      process.kill(state.pid, "SIGKILL")
    }

    await removeServerState()
    log.info("dolt server stopped")
  }

  // Health check — called periodically
  export async function healthCheck(): Promise<"healthy" | "unhealthy" | "not-running"> {
    const state = await loadServerState()
    if (!state) return "not-running"

    // Check if process is alive
    try {
      process.kill(state.pid, 0)  // signal 0 = check existence
    } catch {
      // Process died — clean up state
      await removeServerState()
      return "not-running"
    }

    // Check if responsive to queries
    try {
      const conn = await mysql2.createConnection({
        host: "127.0.0.1",
        port: state.port,
        user: "root",
        connectTimeout: 2000,
      })
      await conn.query("SELECT 1")
      await conn.end()
      return "healthy"
    } catch {
      return "unhealthy"
    }
  }

  // Auto-restart on crash
  export async function ensureRunning(): Promise<ServerState> {
    const health = await healthCheck()

    switch (health) {
      case "healthy":
        return (await loadServerState())!
      case "unhealthy":
        log.warn("dolt server unhealthy, restarting")
        await stop()
        return start()
      case "not-running":
        return start()
    }
  }
}
```

### Lock File Recovery

Beads lesson: kill -9 leaves orphan lock files that prevent restart.

```typescript
async function recoverLockFiles(dataDir: string): Promise<void> {
  // Walk data directory looking for .lock files
  const lockFiles = await glob(path.join(dataDir, "**/.dolt/noms/*.lock"))

  for (const lockFile of lockFiles) {
    // Check if the PID in the lock file is still running
    try {
      const content = await Filesystem.read(lockFile)
      const pid = parseInt(content.trim())
      process.kill(pid, 0)  // throws if process doesn't exist
      // Process is alive — lock is valid
    } catch {
      // Process is dead — remove stale lock
      log.warn("removing stale lock file", { path: lockFile })
      await Filesystem.unlink(lockFile)
    }
  }
}
```

### Data Directory Initialization

```typescript
async function initDataDir(dataDir: string, binary: DoltBinary): Promise<void> {
  // Create directory structure
  await Filesystem.mkdir(dataDir, { recursive: true })

  // Initialize kilo_meta if it doesn't exist
  const metaDir = path.join(dataDir, "kilo_meta")
  if (!(await Filesystem.exists(metaDir))) {
    await Bun.spawn([binary.path, "init"], { cwd: metaDir }).exited
  }

  // Initialize kilo_global if it doesn't exist
  const globalDir = path.join(dataDir, "kilo_global")
  if (!(await Filesystem.exists(globalDir))) {
    await Bun.spawn([binary.path, "init"], { cwd: globalDir }).exited
  }
}
```

## Platform-Specific Process Management

### macOS: launchctl (Optional, For Power Users)

```typescript
// storage/dolt/platform/macos.ts

export async function installLaunchAgent(): Promise<void> {
  const plistPath = path.join(
    process.env.HOME!, "Library", "LaunchAgents",
    "com.kilocode.dolt-server.plist"
  )

  const plist = {
    Label: "com.kilocode.dolt-server",
    ProgramArguments: [
      (await DoltInstall.resolve())!.path,
      "sql-server",
      "--host", "127.0.0.1",
      "--port", String(await DoltServer.getPort()),
      "--data-dir", path.join(Global.Path.data, "dolt"),
    ],
    RunAtLoad: true,
    KeepAlive: true,
    StandardOutPath: path.join(Global.Path.data, "dolt", "server.log"),
    StandardErrorPath: path.join(Global.Path.data, "dolt", "server.err"),
  }

  await Filesystem.write(plistPath, plistToXml(plist))
  await Bun.spawn(["launchctl", "load", plistPath]).exited
}
```

### Linux: systemd User Service (Optional)

```typescript
// storage/dolt/platform/linux.ts

export async function installSystemdService(): Promise<void> {
  const serviceDir = path.join(process.env.HOME!, ".config", "systemd", "user")
  const servicePath = path.join(serviceDir, "kilo-dolt.service")

  const unit = `[Unit]
Description=Kilo Code Dolt Server
After=network.target

[Service]
Type=simple
ExecStart=${(await DoltInstall.resolve())!.path} sql-server \\
  --host 127.0.0.1 \\
  --port ${await DoltServer.getPort()} \\
  --data-dir ${path.join(Global.Path.data, "dolt")}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target`

  await Filesystem.mkdir(serviceDir, { recursive: true })
  await Filesystem.write(servicePath, unit)
  await Bun.spawn(["systemctl", "--user", "enable", "--now", "kilo-dolt"]).exited
}
```

### Default: Kilo-Managed Process (All Platforms)

The default is Kilo managing the process directly (no OS service manager). This
works everywhere including Windows:

```
Kilo starts → DoltServer.ensureRunning() → server starts as child process
Kilo stops  → Server keeps running (not a child; detached)
Next Kilo start → detects running server via port file + health check
```

The server is started **detached** from the Kilo process so it survives Kilo restarts:

```typescript
const proc = Bun.spawn([binary.path, "sql-server", ...args], {
  detached: true,       // survive parent exit
  stdio: "ignore",      // don't hold stdin/stdout
})
proc.unref()            // allow parent to exit independently
```

Power users can upgrade to launchctl/systemd via `kilo db install-service`.

## Coexistence with Existing Dolt Servers

### Detection

```typescript
// storage/dolt/coexist.ts

interface ExistingDoltServer {
  port: number
  dataDir: string
  owner: "kilo" | "other" | "unknown"
  databases: string[]
}

export async function detectExistingServers(): Promise<ExistingDoltServer[]> {
  const servers: ExistingDoltServer[] = []

  // Check common ports
  for (const port of [3306, 3307, 3308, 3309, 3310, 3320]) {
    try {
      const conn = await mysql2.createConnection({
        host: "127.0.0.1",
        port,
        user: "root",
        connectTimeout: 1000,
      })

      // Check if it's a Dolt server (vs MySQL/MariaDB)
      const [version] = await conn.query("SELECT @@version")
      if (!String(version[0]?.["@@version"]).includes("Dolt")) {
        await conn.end()
        continue
      }

      // List databases to identify owner
      const [dbs] = await conn.query("SHOW DATABASES")
      const dbNames = dbs.map((r: any) => r.Database)

      let owner: ExistingDoltServer["owner"] = "unknown"
      if (dbNames.some((d: string) => d.startsWith("kilo_"))) owner = "kilo"
      // Detect other Dolt servers by the presence of non-Kilo databases
      else if (dbNames.length > 1) owner = "other"

      servers.push({ port, dataDir: "unknown", owner, databases: dbNames })
      await conn.end()
    } catch {
      // Port not responding or not MySQL — skip
    }
  }

  return servers
}
```

### Shared Server Option

If a user has an existing Dolt server, Kilo can use it instead of starting its own:

```json
// kilo.json — use existing server
{
  "storage": {
    "backend": "dolt",
    "dolt": {
      "host": "127.0.0.1",
      "port": 3309,
      "managed": false,
      "database": "kilo_myproject"
    }
  }
}
```

When `managed: false`, Kilo skips server lifecycle management and connects directly.
It still creates its own databases (`kilo_*`) on the shared server.

### Auto-Detection on First Run

```typescript
async function firstRunSetup(): Promise<DoltConfig> {
  // 1. Check for existing Kilo server
  const existing = await detectExistingServers()
  const kiloServer = existing.find(s => s.owner === "kilo")
  if (kiloServer) {
    log.info("found existing Kilo Dolt server", { port: kiloServer.port })
    return { port: kiloServer.port, managed: false }
  }

  // 2. Check for shared servers we could use
  const shared = existing.filter(s => s.owner !== "unknown")
  if (shared.length > 0) {
    log.info("found existing Dolt servers", { servers: shared })
    // Could ask user if they want to share, but default to own server
  }

  // 3. Start our own server on an available port
  const port = await findAvailablePort()
  return { port, managed: true }
}
```

## User-Facing Commands

### `kilo db` (Extended)

```
kilo db                     # Interactive SQL shell (connects to Dolt)
kilo db <query>             # Ad-hoc read-only query
kilo db path                # Print data directory path
kilo db status              # Server status, port, databases, disk usage
kilo db start               # Manually start server
kilo db stop                # Manually stop server
kilo db migrate             # Run schema migrations
kilo db push                # Push Gold layer to remote
kilo db pull                # Pull team Gold layer from remote
kilo db gc                  # Run garbage collection on all project databases
kilo db install-service     # Install launchctl/systemd service
kilo db uninstall-service   # Remove OS service
```

### Status Output Example

```
$ kilo db status

Dolt Server: running (pid 12345)
  Port:     3320
  Version:  1.83.0
  Uptime:   2h 15m
  Memory:   142 MB
  Source:    managed (auto-downloaded)

Databases:
  kilo_meta          — 2 tables, 0.1 MB
  kilo_a1b2c3d4      — 9 tables, 45 MB, 3 active sessions
  kilo_e5f6g7h8      — 9 tables, 12 MB, 1 active session
  kilo_global        — 9 tables, 2 MB

Total disk: 59 MB
Port file: ~/.local/share/kilo/dolt/.port
```

## Upgrade Path

### Version Detection + Auto-Upgrade (Managed Installs Only)

```typescript
const UPGRADE_CHECK_INTERVAL = 7 * 24 * 60 * 60 * 1000  // weekly

async function checkForUpgrade(): Promise<void> {
  const binary = await DoltInstall.resolve()
  if (!binary || binary.source !== "managed") return  // don't touch system installs

  const lastCheck = await readUpgradeCheck()
  if (Date.now() - lastCheck < UPGRADE_CHECK_INTERVAL) return

  // Check latest release
  const latest = await getLatestDoltVersion()
  if (latest && semver.gt(latest, binary.version!)) {
    log.info("dolt upgrade available", { current: binary.version, latest })
    // Don't auto-upgrade while server is running — schedule for next start
    await saveUpgradePending(latest)
  }

  await saveUpgradeCheck(Date.now())
}

// On next DoltServer.start(), if upgrade pending:
//   1. Stop server
//   2. Download new binary
//   3. Start server with new binary
```

## Fallback: SQLite When Dolt Unavailable

If `storage.backend = "dolt"` but Dolt can't be installed (no network, restricted
environment, Windows without curl):

```typescript
async function initializeStorage(config: StorageConfig): Promise<StoragePort> {
  if (config.backend === "dolt") {
    try {
      const binary = await DoltInstall.ensure()
      const server = await DoltServer.ensureRunning()
      return new DoltAdapter(server)
    } catch (error) {
      log.warn("dolt unavailable, falling back to sqlite", { error })
      // Graceful degradation — everything works, just no versioning/sharing
      return new SQLiteAdapter(config.sqlite ?? { path: Database.Path })
    }
  }
  // ... other backends
}
```

The user sees a one-time warning, and everything works on SQLite.

## Security Considerations

| Concern | Mitigation |
|---------|-----------|
| Dolt listens on network port | Bind to `127.0.0.1` only (not `0.0.0.0`) |
| No auth by default | Local-only; auth opt-in via `KILO_DOLT_PASSWORD` |
| Binary download from GitHub | HTTPS only, checksum verification |
| Data directory permissions | Created with `0700` (owner-only) |
| Team sharing auth | DoltHub/DoltLab handle remote auth separately |
| Binary integrity | Compare downloaded SHA against GitHub release checksums |

## Summary: Installation Matrix

| Scenario | Binary Source | Server | Port | Config |
|----------|-------------|--------|------|--------|
| **New user, no Dolt** | Auto-download from GitHub | Kilo-managed, detached | Dynamic (default 3307) | Zero-config |
| **User has Dolt (brew)** | System PATH | Kilo-managed, system binary | Dynamic | Zero-config |
| **User has Dolt server** | System PATH | User's server (`managed: false`) | User's port | `kilo.json` |
| **Existing Dolt user** | System PATH | Own server (different port) | Dynamic (avoids conflicts) | Auto-detected |
| **Team deployment** | System install | Shared server | Configured | `kilo.json` |
| **Restricted env** | N/A | N/A | N/A | Falls back to SQLite |
| **Windows** | Auto-download zip | Kilo-managed | Dynamic | Zero-config |

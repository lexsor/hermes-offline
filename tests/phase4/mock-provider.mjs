// Phase 4 mock inference provider.
//
// Runs upstream's OpenAI-compatible mock (tests-js/scripts/mock-server.ts,
// Node built-ins only) under the bundled Node runtime, with no npm install.
// Node 26 strips the TypeScript types natively.
//
// Usage: node mock-provider.mjs <path-to-mock-server.ts> <state.json>
//
// The state file is rewritten every 500 ms with the loopback URL and every
// prompt/model the mock has received, so the harness can assert that a
// chat actually reached it.

import fs from 'node:fs'
import { pathToFileURL } from 'node:url'

const [, , mockModulePath, stateFile] = process.argv
if (!mockModulePath || !stateFile) {
  console.error('usage: node mock-provider.mjs <mock-server.ts> <state.json>')
  process.exit(2)
}

const { startMockServer, MOCK_REPLY } = await import(pathToFileURL(mockModulePath).href)
const server = await startMockServer()

function writeState(status) {
  const state = {
    status,
    pid: process.pid,
    port: server.port,
    url: server.url,
    reply: MOCK_REPLY,
    prompts: server.receivedPrompts,
    models: server.receivedModels,
    updated_at: new Date().toISOString(),
  }
  const temporary = `${stateFile}.tmp`
  fs.writeFileSync(temporary, JSON.stringify(state, null, 2))
  fs.renameSync(temporary, stateFile)
}

writeState('listening')
console.log(`mock provider listening on ${server.url}`)
const timer = setInterval(() => writeState('listening'), 500)

async function shutdown() {
  clearInterval(timer)
  writeState('stopped')
  await server.close()
  process.exit(0)
}
// Ctrl+C when run by hand. The harness stops it with Stop-Process; stdin is
// deliberately not watched because Start-Process gives it none.
process.on('SIGINT', shutdown)
process.on('SIGTERM', shutdown)

#!/usr/bin/env bash
set -euo pipefail

project_root=$(git rev-parse --show-toplevel)
fixture=$(mktemp -d /tmp/agent-board-two-nvim-XXXXXX)
repo="$fixture/repo"
client_a_pid=

cleanup() {
  if [ -n "$client_a_pid" ]; then
    kill "$client_a_pid" 2>/dev/null || true
    wait "$client_a_pid" 2>/dev/null || true
  fi
  FIXTURE="$fixture" python3 - <<'PY'
from pathlib import Path
import os, shutil
path = Path(os.environ['FIXTURE'])
assert path.parent == Path('/tmp') and path.name.startswith('agent-board-two-nvim-')
shutil.rmtree(path, ignore_errors=True)
PY
}
trap cleanup EXIT

mkdir -p "$repo" "$fixture/data"
git init -q --initial-branch=main "$repo"
cat > "$repo/.agent-board.json" <<'JSON'
{"version":1,"revision":0,"tasks":[{"id":"stale-test","title":"Before concurrent update","status":"todo","agent":null}]}
JSON

cat > "$fixture/client-a.lua" <<'LUA'
local root = vim.env.TEST_REPO
local base = vim.env.AGENT_BOARD_ROOT
package.path = base .. '/lua/?.lua;' .. base .. '/lua/?/init.lua;' .. package.path
local storage = require('agent-board.storage')
local tasks = require('agent-board.tasks')
local api = require('agent-board')
storage.registry_path = function() return vim.env.TEST_DATA .. '/repos.json' end
assert(tasks.register_repo(root))
local rows, _, snapshots = tasks.list_tasks({ scope = 'repo', repo = root })
assert(rows and rows[1].task.title == 'Before concurrent update')
vim.fn.writefile({ 'ready' }, vim.env.TEST_READY)
assert(vim.wait(10000, function() return vim.fn.filereadable(vim.env.TEST_GO) == 1 end, 10), 'writer B timed out')
local moved, err = api.move_task({ repo = root, id = 'stale-test' }, 'done', snapshots[root])
assert(moved == nil and type(err) == 'string' and err:find('reload', 1, true), vim.inspect(err))
vim.fn.writefile({ err }, vim.env.TEST_RESULT)
print('Neovim A rejected stale snapshot with reload-required error')
LUA

cat > "$fixture/client-b.lua" <<'LUA'
local root = vim.env.TEST_REPO
local base = vim.env.AGENT_BOARD_ROOT
package.path = base .. '/lua/?.lua;' .. base .. '/lua/?/init.lua;' .. package.path
local storage = require('agent-board.storage')
local tasks = require('agent-board.tasks')
local api = require('agent-board')
storage.registry_path = function() return vim.env.TEST_DATA .. '/repos.json' end
assert(tasks.register_repo(root))
local rows, _, snapshots = tasks.list_tasks({ scope = 'repo', repo = root })
assert(rows and rows[1].task.title == 'Before concurrent update')
local updated, err = api.update_task({ repo = root, id = 'stale-test' }, { title = 'Fresh update from Neovim B' }, snapshots[root])
assert(updated and not err, vim.inspect(err))
print('Neovim B saved a newer task revision')
LUA

TEST_REPO="$repo" TEST_DATA="$fixture/data" TEST_READY="$fixture/ready" TEST_GO="$fixture/go" TEST_RESULT="$fixture/result" AGENT_BOARD_ROOT="$project_root" \
  nvim --headless -u NONE -l "$fixture/client-a.lua" > "$fixture/a.log" 2>&1 &
client_a_pid=$!

ready=0
for _ in $(seq 1 200); do
  if [ -f "$fixture/ready" ]; then ready=1; break; fi
  sleep 0.05
done
if [ "$ready" -ne 1 ]; then cat "$fixture/a.log"; exit 1; fi

TEST_REPO="$repo" TEST_DATA="$fixture/data" AGENT_BOARD_ROOT="$project_root" \
  nvim --headless -u NONE -l "$fixture/client-b.lua" > "$fixture/b.log" 2>&1
: > "$fixture/go"
wait "$client_a_pid"
client_a_pid=

python3 - "$repo/.agent-board.json" <<'PY'
import json
import sys
from pathlib import Path

board = json.loads(Path(sys.argv[1]).read_text())
assert board['revision'] == 1
assert board['tasks'][0]['title'] == 'Fresh update from Neovim B'
assert board['tasks'][0]['status'] == 'todo'
PY

cat "$fixture/a.log" "$fixture/b.log" "$fixture/result"
cat "$repo/.agent-board.json"

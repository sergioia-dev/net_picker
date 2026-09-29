-- net_picker.fzf — fzf-lua backend for net_picker.nvim
--
-- Network process picker + container awareness.
-- Requirements: fzf-lua. Optional: a running podman/docker socket.
--
-- Bindings inside the picker:
--   Tab      multi-select (deduped by PID)
--   Enter    kill (SIGTERM + confirm)
--   C-k      kill (SIGTERM + confirm)     — same as Enter
--   C-s      signal submenu (TERM/KILL/HUP/INT/USR1/USR2/STOP/CONT)
--   C-t      tail log in a persistent split (with C-g grep inside)
--   C-r      restart (kill + relaunch cmdline in a terminal)
--   C-d      debugger submenu (gdb/strace/py-spy/lsof/cat cmdline)
--   C-o      cd to the process's cwd
--   C-y      yank submenu (kill cmd / JSON / markdown / full info)
--   C-g      jump to source file named in cmdline

local fzf = require("fzf-lua")

local uv = vim.uv or vim.loop

local M = {}

----------------------------------------------------------------------
-- Caches
----------------------------------------------------------------------

local info_cache = {}
local log_cache = {}

local function clear_caches()
	info_cache = {}
	log_cache = {}
end

-- Networking helpers spawned by rootless podman/docker. These hold the
-- host-side ports that published containers rely on, so killing them
-- breaks connectivity without stopping the container. When container
-- rows are present, we hide these to avoid that trap.
local CONTAINER_NET_HELPERS = {
	"rootlessport",
	"rootlessp", -- lsof truncation
	"passt", -- passt.avx, passt.avx2
	"pasta", -- pasta.avx, pasta.avx2
	"slirp4netns",
	"pesto",
}

local function is_container_net_helper(name)
	if not name or name == "" then
		return false
	end
	local lower = name:lower()
	for _, prefix in ipairs(CONTAINER_NET_HELPERS) do
		if lower:sub(1, #prefix) == prefix then
			return true
		end
	end
	return false
end

-- Drop helper processes from the list. Only runs when containers exist,
-- so a machine with no containers keeps its full process view.
local function filter_container_helpers(processes, containers)
	if not containers or #containers == 0 then
		return processes
	end
	local out = {}
	for _, p in ipairs(processes) do
		if not is_container_net_helper(p.command) then
			table.insert(out, p)
		end
	end
	return out
end
----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

-- Rows are rendered as "<display>\t<index>": fzf only hands back the
-- selected line, so the hidden field maps a line back to its row.
local rows_by_index = {}

local function set_rows(rows)
	rows_by_index = {}
	for _, row in ipairs(rows or {}) do
		row.index = row.index or #rows_by_index + 1
		rows_by_index[row.index] = row
	end
end

local function row_from_line(line)
	local index = tostring(line or ""):match("\t(%d+)$")
	if not index then
		return nil
	end
	return rows_by_index[tonumber(index)]
end

local function format_row(row)
	local cmd = tostring(row.command or "?")
	local pid = tostring(row.pid or "")
	local user = tostring(row.user or "?")

	local ports = tostring(row.ports or "")
	if row.is_container then
		return string.format("%-24s  [container]  ports=%-24s  pid=%s", cmd, ports, pid)
	end
	return string.format("%-16s  pid=%-7s  ports=%-16s  %s", cmd, pid, ports, user)
end

-- Dedupe the selection the way the old picker did: one entry per PID and
-- one entry per container.
local function selected_rows(selected)
	local result, seen = {}, {}
	for _, line in ipairs(selected or {}) do
		local row = row_from_line(line)
		if row then
			local key
			if row.is_container and row.container_id then
				key = "c:" .. row.container_id
			elseif row.pid and row.pid ~= "" and row.pid ~= "-" then
				key = tostring(row.pid)
			elseif row.is_container then
				key = "c:?"
			end
			if key and not seen[key] then
				seen[key] = true
				table.insert(result, row)
			end
		end
	end
	return result
end

-- Extract local port from an lsof line, skipping IPv6 bracket noise.
local function extract_port(line)
	return line:match("[%*%]]:(%d+)") or line:match("[%d%.]:([%d]+)") or line:match(":(%d+)") or ""
end

local function dedupe_by_pid(lines)
	local by_pid, order = {}, {}

	for _, line in ipairs(lines) do
		local command, pid, user = line:match("^(%S+)%s+(%d+)%s+(%S+)")
		if pid then
			command = command or "?"
			user = user or "?"
			local port = extract_port(line)

			if not by_pid[pid] then
				by_pid[pid] = {
					command = command,
					pid = pid,
					user = user,
					ports = {},
					port_set = {},
				}
				table.insert(order, pid)
			end

			local e = by_pid[pid]
			if port ~= "" and not e.port_set[port] then
				e.port_set[port] = true
				table.insert(e.ports, port)
			end
		end
	end

	local out = {}
	for _, pid in ipairs(order) do
		local e = by_pid[pid]
		table.sort(e.ports, function(a, b)
			return tonumber(a) < tonumber(b)
		end)
		e.ports_str = table.concat(e.ports, ",")
		out[#out + 1] = e
	end
	return out
end

-- Render a container's ports as "host->container" (or just the side that
-- is known), so an unpublished container still shows the port it listens on.
local function format_container_ports(ports)
	local acc, seen = {}, {}
	for _, p in ipairs(ports or {}) do
		local host = tostring(p.hostPort or p.host_port or "")
		local ctr = tostring(p.containerPort or p.container_port or "")
		if host == "0" then
			host = ""
		end
		if host == ctr then
			ctr = ""
		end

		local label
		if host ~= "" and ctr ~= "" then
			label = host .. "->" .. ctr
		elseif host ~= "" then
			label = host
		elseif ctr ~= "" then
			label = ctr
		end

		local proto = tostring(p.protocol or "tcp"):lower()
		if label then
			if proto ~= "tcp" then
				label = label .. "/" .. proto
			end
			if not seen[label] then
				seen[label] = true
				table.insert(acc, label)
			end
		end
	end
	return table.concat(acc, ",")
end

local function build_rows(processes, containers)
	local out = {}

	-- Container rows fall back to the ports held by their own processes when
	-- the runtime API gave us nothing (proc-only mode / unpublished ports).
	local ports_by_pid = {}
	for _, p in ipairs(processes) do
		if p.pid and p.ports_str and p.ports_str ~= "" then
			ports_by_pid[tostring(p.pid)] = p.ports_str
		end
	end

	for _, p in ipairs(processes) do
		table.insert(out, {
			command = p.command or "?",
			pid = p.pid or "",
			user = p.user or "?",
			ports = p.ports_str or "",
			is_container = false,
		})
	end

	for _, c in ipairs(containers or {}) do
		local pids = c.pids or {}
		local pid_label = "-"
		if #pids == 1 then
			pid_label = tostring(pids[1])
		elseif #pids > 1 then
			pid_label = tostring(pids[1]) .. "+" .. (#pids - 1)
		end

		local ports_str = format_container_ports(c.ports)
		if ports_str == "" then
			local acc, seen = {}, {}
			for _, pid in ipairs(pids) do
				local s = ports_by_pid[tostring(pid)]
				if s and not seen[s] then
					seen[s] = true
					table.insert(acc, s)
				end
			end
			ports_str = table.concat(acc, ",")
		end

		table.insert(out, {
			command = c.name or "?",
			pid = pid_label,
			user = "container",
			ports = ports_str,
			is_container = true,
			container_id = c.id,
		})
	end

	return out
end

local function get_info(pid)
	pid = tostring(pid)
	if info_cache[pid] then
		return info_cache[pid]
	end
	local info = { pid = pid }

	local args = vim.fn.systemlist({ "ps", "-p", pid, "-o", "args=" })
	if vim.v.shell_error == 0 and #args > 0 and args[1] ~= "" then
		info.cmdline = vim.trim(args[1])
	end

	local cwd_lines = vim.fn.systemlist({ "readlink", "/proc/" .. pid .. "/cwd" })
	if vim.v.shell_error == 0 and #cwd_lines > 0 and cwd_lines[1] ~= "" then
		info.cwd = cwd_lines[1]
	else
		local lsof = vim.fn.systemlist({ "lsof", "-a", "-p", pid, "-d", "cwd", "-Fn" })
		for _, l in ipairs(lsof) do
			if l:sub(1, 1) == "n" then
				info.cwd = l:sub(2)
				break
			end
		end
	end

	local etime = vim.fn.systemlist({ "ps", "-p", pid, "-o", "etime=" })
	if vim.v.shell_error == 0 and #etime > 0 and etime[1] ~= "" then
		info.uptime = vim.trim(etime[1])
	end

	info_cache[pid] = info
	return info
end

local function find_log_file(pid)
	pid = tostring(pid)
	if log_cache[pid] ~= nil then
		return log_cache[pid] == false and nil or log_cache[pid]
	end

	local info = get_info(pid)
	if not info.cwd then
		log_cache[pid] = false
		return nil
	end

	local dirs = {
		info.cwd .. "/logs",
		info.cwd .. "/log",
		info.cwd .. "/tmp/logs",
		info.cwd .. "/var/log",
		info.cwd,
	}
	local best, best_mtime = nil, 0
	for _, dir in ipairs(dirs) do
		if vim.fn.isdirectory(dir) == 1 then
			local files = vim.fn.glob(dir .. "/*.log", false, true)
			for _, f in ipairs(files) do
				local mtime = vim.fn.getftime(f)
				if mtime > best_mtime then
					best, best_mtime = f, mtime
				end
			end
		end
	end

	log_cache[pid] = best or false
	return best
end

local function kill_pids(pids, signal)
	signal = signal or "-TERM"
	local killed, failed = {}, {}
	for _, pid in ipairs(pids) do
		vim.fn.system({ "kill", signal, tostring(pid) })
		if vim.v.shell_error == 0 then
			table.insert(killed, tostring(pid))
		else
			table.insert(failed, tostring(pid))
		end
	end
	return killed, failed
end

local function open_terminal(cmd, cwd)
	vim.cmd("botright new")
	vim.fn.jobstart(cmd, { term = true, cwd = cwd })
	vim.cmd("startinsert")
end

----------------------------------------------------------------------
-- Container runtime (socket + /proc fallback)
----------------------------------------------------------------------

local _runtime_cache = nil

local function socket_candidates()
	local uid = (vim.fn.system("id -u") or "1000"):gsub("%s+", "")
	local xdg = os.getenv("XDG_RUNTIME_DIR") or ("/run/user/" .. uid)
	return {
		{ path = xdg .. "/podman/podman.sock", api = "podman" },
		{ path = xdg .. "/docker.sock", api = "docker" },
		{ path = "/run/podman/podman.sock", api = "podman" },
		{ path = "/var/run/docker.sock", api = "docker" },
	}
end

local function http_over_unix(sock_path, method, path, body, timeout_ms)
	timeout_ms = timeout_ms or 3000
	local pipe = uv.new_pipe(false)
	local chunks = {}
	local done, err_msg = false, nil

	pipe:connect(sock_path, function(err)
		if err then
			err_msg = tostring(err)
			done = true
			return
		end
		local headers = {
			method .. " " .. path .. " HTTP/1.1",
			"Host: localhost",
			"Connection: close",
		}
		if body then
			table.insert(headers, "Content-Type: application/json")
			table.insert(headers, "Content-Length: " .. #body)
		end
		pipe:write(table.concat(headers, "\r\n") .. "\r\n\r\n" .. (body or ""))
	end)

	pipe:read_start(function(err, data)
		if err then
			err_msg = tostring(err)
			done = true
			return
		end
		if data then
			table.insert(chunks, data)
		else
			done = true
			pcall(function()
				pipe:close()
			end)
		end
	end)

	vim.wait(timeout_ms, function()
		return done
	end)
	if not done then
		pcall(function()
			pipe:close()
		end)
		return nil, "timeout"
	end
	if err_msg then
		return nil, err_msg
	end

	local raw = table.concat(chunks)
	local status, rest = raw:match("^HTTP/%d%.%d%s+(%d+)[^\r\n]*\r\n(.*)$")
	if not status then
		return nil, "malformed response"
	end

	local header_block, body_block = rest:match("^(.-)\r\n\r\n(.*)$")
	if not header_block then
		return tonumber(status), ""
	end

	local len = tonumber(header_block:match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
	if len then
		return tonumber(status), body_block:sub(1, len)
	end

	if header_block:lower():find("transfer%-encoding:%s*chunked") then
		local decoded, pos = {}, 1
		while pos <= #body_block do
			local size_hex, after = body_block:match("^(%x+)\r\n()", pos)
			if not size_hex then
				break
			end
			local size = tonumber(size_hex, 16)
			if size == 0 then
				break
			end
			table.insert(decoded, body_block:sub(after, after + size - 1))
			pos = after + size + 2
		end
		return tonumber(status), table.concat(decoded)
	end

	return tonumber(status), body_block
end

local function detect_runtime()
	if _runtime_cache then
		return _runtime_cache
	end
	for _, c in ipairs(socket_candidates()) do
		if vim.fn.getftype(c.path) == "socket" then
			local ping = c.api == "podman" and "/v4.0.0/libpod/_ping" or "/_ping"
			local status = http_over_unix(c.path, "GET", ping, nil, 1000)
			if status == 200 then
				_runtime_cache = { kind = "socket", api = c.api, path = c.path }
				return _runtime_cache
			end
		end
	end
	_runtime_cache = { kind = "proc" }
	return _runtime_cache
end

local function list_from_socket(rt)
	local path = rt.api == "podman" and "/v4.0.0/libpod/containers/json?all=false" or "/containers/json?all=false"

	local status, body = http_over_unix(rt.path, "GET", path)
	if status ~= 200 then
		return nil, body or ("HTTP " .. tostring(status))
	end

	local ok, list = pcall(vim.json.decode, body)
	if not ok or type(list) ~= "table" then
		return nil, "bad JSON"
	end

	local function as_table(v)
		if type(v) == "table" then
			return v
		end
		return {}
	end

	return vim.tbl_map(function(c)
		if type(c) ~= "table" then
			return { id = "", name = "", image = "", ports = {} }
		end

		local names = as_table(c.Names)
		local name = names[1] or c.Name or c.name or ""

		local ports = {}
		for _, p in ipairs(as_table(c.Ports)) do
			if type(p) == "table" then
				-- libpod uses snake_case; docker-compat uses PublicPort/PrivatePort
				local host = p.host_port or p.hostPort or p.PublicPort
				local ctr = p.container_port or p.containerPort or p.PrivatePort
				if host == 0 then
					host = nil
				end
				-- Keep the entry when either side is known: an unpublished
				-- container still listens on its own (container) port.
				if host or ctr then
					table.insert(ports, {
						hostPort = host,
						containerPort = ctr,
						protocol = p.protocol or p.Type or "tcp",
					})
				end
			end
		end

		return {
			id = c.Id or c.ID or "",
			name = (tostring(name):gsub("^/", "")),
			image = c.Image or c.image or "",
			ports = ports,
		}
	end, list)
end

-- Fetch the host PID of a container's init process from the runtime socket.
-- Podman: GET /v4.0.0/libpod/containers/<id>/json   → .State.Pid
-- Docker: GET /containers/<id>/json                 → .State.Pid
local function fetch_pid_from_socket(rt, id)
	if not id or id == "" then
		return nil
	end
	local path = rt.api == "podman" and ("/v4.0.0/libpod/containers/" .. id .. "/json")
		or ("/containers/" .. id .. "/json")

	local status, body = http_over_unix(rt.path, "GET", path, nil, 2000)
	if status ~= 200 then
		return nil
	end

	local ok, obj = pcall(vim.json.decode, body)
	if not ok or type(obj) ~= "table" then
		return nil
	end

	local state = obj.State
	if type(state) == "table" and state.Pid and state.Pid ~= 0 then
		return tonumber(state.Pid)
	end
	return nil
end

local function pid_to_container_id(pid)
	local path = "/proc/" .. pid .. "/cgroup"
	if vim.fn.filereadable(path) == 0 then
		return nil
	end
	for _, line in ipairs(vim.fn.readfile(path)) do
		local id = line:match("libpod%-(%w+)%.scope")
			or line:match("docker%-(%w+)%.scope")
			or line:match("cri%-containerd%-(%w+)%.scope")
			or line:match("crio%-(%w+)%.scope")
		if id then
			return id
		end
	end
	return nil
end

local function pids_for_all_containers()
	local map = {}
	for _, p in ipairs(vim.fn.glob("/proc/[0-9]*", false, true)) do
		local pid = p:match("/(%d+)$")
		if pid then
			local cid = pid_to_container_id(pid)
			if cid then
				map[cid] = map[cid] or {}
				table.insert(map[cid], tonumber(pid))
			end
		end
	end
	return map
end

local function runtime_state_dirs()
	local uid = (vim.fn.system("id -u") or "1000"):gsub("%s+", "")
	local xdg = os.getenv("XDG_RUNTIME_DIR") or ("/run/user/" .. uid)
	return {
		xdg .. "/containers/overlay-containers",
		xdg .. "/containers/storage/overlay-containers",
		"/run/containers/storage/overlay-containers",
	}
end

local function read_container_config(id)
	for _, base in ipairs(runtime_state_dirs()) do
		local cfg = base .. "/" .. id .. "/userdata/config.json"
		if vim.fn.filereadable(cfg) == 1 then
			local raw = table.concat(vim.fn.readfile(cfg), "")
			local ok, obj = pcall(vim.json.decode, raw)
			if ok and type(obj) == "table" then
				return obj
			end
		end
	end
	return nil
end

local function list_from_proc()
	local ids = {}
	for _, p in ipairs(vim.fn.glob("/proc/[0-9]*", false, true)) do
		local pid = p:match("/(%d+)$")
		if pid then
			local cid = pid_to_container_id(pid)
			if cid then
				ids[cid] = ids[cid] or {}
				table.insert(ids[cid], tonumber(pid))
			end
		end
	end

	local out = {}
	for id, pids in pairs(ids) do
		local cfg = read_container_config(id)
		table.insert(out, {
			id = id,
			name = (cfg and cfg.name) or id:sub(1, 12),
			image = (cfg and (cfg.rootfsImageName or cfg.image)) or "",
			ports = {}, -- not available without the socket
			pids = pids,
		})
	end
	return out
end

local function list_containers()
	local detect_ok, rt = pcall(detect_runtime)
	if not detect_ok or type(rt) ~= "table" then
		return list_from_proc()
	end

	local out
	local via_socket = false

	if rt.kind == "socket" then
		local sock_ok, list, err = pcall(list_from_socket, rt)
		if sock_ok and type(list) == "table" then
			out = list
			via_socket = true
		else
			vim.notify(
				"container list via socket failed: " .. (sock_ok and tostring(err) or tostring(list)),
				vim.log.levels.WARN
			)
			_runtime_cache = { kind = "proc" }
			out = list_from_proc()
		end
	else
		out = list_from_proc()
	end

	if not out or #out == 0 then
		return out or {}
	end

	-- Preferred: ask the socket for each container's PID.
	if via_socket then
		for _, c in ipairs(out) do
			local pid = fetch_pid_from_socket(rt, c.id)
			if pid then
				c.pids = { pid }
			else
				c.pids = {}
			end
		end
	end

	-- Fill any missing PIDs via cgroup walk.
	local any_missing = false
	for _, c in ipairs(out) do
		if not c.pids or #c.pids == 0 then
			any_missing = true
			break
		end
	end

	if any_missing then
		local id_to_pids = pids_for_all_containers()
		for _, c in ipairs(out) do
			if not c.pids or #c.pids == 0 then
				local pids = id_to_pids[c.id]
				if not pids and c.id and #c.id >= 12 then
					local short = c.id:sub(1, 12)
					for cid, ps in pairs(id_to_pids) do
						if cid:sub(1, 12) == short then
							pids = ps
							break
						end
					end
				end
				c.pids = pids or {}
			end
		end
	end

	return out
end

local function stop_container(name_or_id)
	local rt = detect_runtime()
	if rt.kind ~= "socket" then
		return false, "no runtime socket — cannot stop containers in /proc mode"
	end
	local path = rt.api == "podman" and ("/v4.0.0/libpod/containers/" .. name_or_id .. "/stop")
		or ("/containers/" .. name_or_id .. "/stop")
	local status = http_over_unix(rt.path, "POST", path, "{}", 15000)
	if status == 204 or status == 200 or status == 304 then
		return true
	end
	return false, "HTTP " .. tostring(status)
end

----------------------------------------------------------------------
-- Log previewer (right pane)
----------------------------------------------------------------------

local function log_preview(items)
	local line = items and items[1]
	local row = line and row_from_line(line)
	if not row then
		return {}
	end

	if row.is_container then
		return {
			"Container: " .. (row.command or "?"),
			"ID:        " .. (row.container_id or "?"),
			"Ports:     " .. (row.ports or ""),
			"",
			"Preview of container logs is not wired here.",
			"Use `podman logs <name>` in a terminal, or add a socket-backed preview.",
		}
	end

	if not row.pid or row.pid == "" or row.pid == "-" then
		return {}
	end

	local logfile = find_log_file(row.pid)
	if not logfile then
		return {}
	end

	local content = vim.fn.systemlist({ "tail", "-n", "500", logfile })
	if vim.v.shell_error ~= 0 or #content == 0 then
		return {}
	end
	return content
end

----------------------------------------------------------------------
-- Actions
----------------------------------------------------------------------

local function do_kill(rows, signal)
	signal = signal or "-TERM"
	rows = rows or {}
	if #rows == 0 then
		return
	end

	local containers, processes = {}, {}
	local seen_c, seen_p = {}, {}
	for _, t in ipairs(rows) do
		if t.is_container and t.container_id then
			if not seen_c[t.container_id] then
				seen_c[t.container_id] = true
				table.insert(containers, t)
			end
		elseif t.pid and t.pid ~= "" and t.pid ~= "-" then
			if not seen_p[t.pid] then
				seen_p[t.pid] = true
				table.insert(processes, t)
			end
		end
	end

	local lines = {}
	for _, c in ipairs(containers) do
		table.insert(lines, string.format("  [container] %s  ports=%s", c.command, c.ports or ""))
	end
	for _, p in ipairs(processes) do
		table.insert(lines, string.format("  %s  pid=%s  ports=%s", p.command, p.pid, p.ports or ""))
	end

	local msg = string.format("Send %s to %d target(s)?\n%s", signal, #containers + #processes, table.concat(lines, "\n"))
	if vim.fn.confirm(msg, "&Yes\n&No", 2) ~= 1 then
		return
	end

	vim.schedule(function()
		for _, c in ipairs(containers) do
			local ok, err = stop_container(c.container_id)
			if ok then
				vim.notify("Stopped container " .. c.command, vim.log.levels.INFO)
			else
				vim.notify("Container stop failed: " .. tostring(err), vim.log.levels.ERROR)
			end
		end
		if #processes > 0 then
			local pids = {}
			for _, p in ipairs(processes) do
				table.insert(pids, p.pid)
			end
			local killed, failed = kill_pids(pids, signal)
			if #killed > 0 then
				vim.notify(string.format("%s → PIDs: %s", signal, table.concat(killed, ", ")), vim.log.levels.INFO)
			end
			if #failed > 0 then
				vim.notify("Failed: " .. table.concat(failed, ", "), vim.log.levels.ERROR)
			end
		end
	end)
end

local SIGNALS = {
	{ name = "SIGTERM (15) — graceful stop", flag = "-TERM" },
	{ name = "SIGKILL (9)  — force kill", flag = "-KILL" },
	{ name = "SIGHUP (1)   — reload config", flag = "-HUP" },
	{ name = "SIGINT (2)   — interrupt", flag = "-INT" },
	{ name = "SIGUSR1      — user signal 1", flag = "-USR1" },
	{ name = "SIGUSR2      — user signal 2", flag = "-USR2" },
	{ name = "SIGSTOP      — pause", flag = "-STOP" },
	{ name = "SIGCONT      — resume", flag = "-CONT" },
}

local function signal_menu(rows)
	rows = rows or {}
	if #rows == 0 then
		return
	end

	local has_container = false
	local pids = {}
	for _, t in ipairs(rows) do
		if t.is_container then
			has_container = true
		elseif t.pid and t.pid ~= "" and t.pid ~= "-" then
			table.insert(pids, t.pid)
		end
	end
	if has_container then
		vim.notify("Signals are not sent to containers — use C-k to stop them", vim.log.levels.WARN)
	end
	if #pids == 0 then
		return
	end

	vim.ui.select(SIGNALS, {
		prompt = string.format("Signal for %d process(es):", #pids),
		format_item = function(s)
			return s.name
		end,
	}, function(choice)
		if not choice then
			return
		end
		local killed, failed = kill_pids(pids, choice.flag)
		if #killed > 0 then
			vim.notify(string.format("%s → %s", choice.flag, table.concat(killed, ", ")), vim.log.levels.INFO)
		end
		if #failed > 0 then
			vim.notify("Failed: " .. table.concat(failed, ", "), vim.log.levels.ERROR)
		end
	end)
end

local function tail_in_split(logfile, title)
	if vim.fn.executable("tail") == 0 then
		vim.notify("`tail` not found in PATH", vim.log.levels.ERROR)
		return
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "log"

	vim.cmd("botright vsplit")
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	pcall(vim.api.nvim_buf_set_name, buf, title or ("log://" .. logfile))

	local MAX, count = 10000, 0
	local function append(line)
		if not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		vim.bo[buf].modifiable = true
		if count >= MAX then
			local drop = math.floor(MAX * 0.1)
			vim.api.nvim_buf_set_lines(buf, 0, drop, false, {})
			count = count - drop
		end
		vim.api.nvim_buf_set_lines(buf, -1, -1, false, { line })
		count = count + 1
		vim.bo[buf].modifiable = false
		if vim.api.nvim_win_is_valid(win) then
			local last = vim.api.nvim_buf_line_count(buf)
			pcall(vim.api.nvim_win_set_cursor, win, { last, 0 })
		end
	end

	local job = vim.fn.jobstart({ "tail", "-F", "-n", "200", logfile }, {
		stdout_buffered = false,
		on_stdout = function(_, data)
			if not data then
				return
			end
			for _, line in ipairs(data) do
				if line ~= "" then
					vim.schedule(function()
						append(line)
					end)
				end
			end
		end,
	})

	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once = true,
		callback = function()
			pcall(vim.fn.jobstop, job)
		end,
	})

	vim.keymap.set("n", "<C-g>", function()
		require("fzf-lua").live_grep({
			filename = logfile,
			prompt = "Grep log: " .. vim.fn.fnamemodify(logfile, ":t") .. " > ",
		})
	end, { buffer = buf, desc = "Live grep this log" })

	local close = function()
		pcall(vim.fn.jobstop, job)
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end
	vim.keymap.set("n", "q", close, { buffer = buf, desc = "Close log panel" })
	vim.keymap.set("n", "<C-c>", close, { buffer = buf, desc = "Close log panel" })

	vim.notify("Tailing " .. logfile .. "  ·  <C-g> grep · q close", vim.log.levels.INFO)
end

local function tail_logs(entry)
	if entry.is_container then
		vim.notify("Container log tail is not wired — run `podman logs " .. entry.command .. "`", vim.log.levels.WARN)
		return
	end
	local logfile = find_log_file(entry.pid)
	if not logfile then
		vim.notify("No *.log found for PID " .. entry.pid, vim.log.levels.WARN)
		return
	end
	tail_in_split(logfile, "log://" .. entry.command .. "[" .. entry.pid .. "]")
end

local function restart(entry)
	if entry.is_container then
		vim.notify(
			"Restart not supported for containers here — use `podman restart " .. entry.command .. "`",
			vim.log.levels.WARN
		)
		return
	end
	local info = get_info(entry.pid)
	if not info.cmdline or info.cmdline == "" then
		vim.notify("Cannot restart: no command line for PID " .. entry.pid, vim.log.levels.ERROR)
		return
	end
	local _, failed = kill_pids({ entry.pid }, "-TERM")
	if #failed > 0 then
		vim.notify("Kill failed for PID " .. entry.pid, vim.log.levels.ERROR)
		return
	end
	vim.notify("Restarting: " .. info.cmdline, vim.log.levels.INFO)
	vim.defer_fn(function()
		open_terminal(vim.fn.split(info.cmdline, "%s+"), info.cwd)
	end, 500)
end

local DEBUGGERS = {
	{
		name = "gdb -p",
		cmd = function(pid)
			return { "gdb", "-p", pid }
		end,
	},
	{
		name = "strace -p",
		cmd = function(pid)
			return { "strace", "-p", pid }
		end,
	},
	{
		name = "py-spy top",
		cmd = function(pid)
			return { "py-spy", "top", "--pid", pid }
		end,
	},
	{
		name = "lsof -p (files)",
		cmd = function(pid)
			return { "lsof", "-p", pid }
		end,
	},
	{
		name = "cat /proc/…/cmdline",
		cmd = function(pid)
			return { "cat", "/proc/" .. pid .. "/cmdline" }
		end,
	},
}

local function debugger_menu(entry)
	if entry.is_container then
		vim.notify("Debugger menu not wired for containers", vim.log.levels.WARN)
		return
	end
	vim.ui.select(DEBUGGERS, {
		prompt = "Debug PID " .. entry.pid .. ":",
		format_item = function(d)
			return d.name
		end,
	}, function(choice)
		if not choice then
			return
		end
		open_terminal(choice.cmd(entry.pid), nil)
	end)
end

local function open_project(entry)
	if entry.is_container then
		vim.notify("No host cwd for container " .. entry.command, vim.log.levels.WARN)
		return
	end
	local info = get_info(entry.pid)
	if not info.cwd then
		vim.notify("No cwd for PID " .. entry.pid, vim.log.levels.WARN)
		return
	end
	vim.fn.chdir(info.cwd)
	vim.notify("cwd → " .. info.cwd, vim.log.levels.INFO)
end

local COPY_OPTIONS = {
	{
		name = "kill command",
		fn = function(e)
			if e.is_container then
				return "podman stop " .. e.command
			end
			return "kill -9 " .. e.pid
		end,
	},
	{
		name = "JSON",
		fn = function(e)
			return vim.json.encode({
				command = e.command,
				pid = e.pid,
				ports = e.ports,
				user = e.user,
				is_container = e.is_container or false,
				container_id = e.container_id,
			})
		end,
	},
	{
		name = "Markdown table row",
		fn = function(e)
			return string.format("| %s | %s | %s | %s |", e.command, e.pid, e.ports, e.user)
		end,
	},
	{
		name = "full info",
		fn = function(e)
			if e.is_container then
				return table.concat({
					"container: " .. e.command,
					"id:        " .. (e.container_id or "?"),
					"ports:     " .. (e.ports or ""),
				}, "\n")
			end
			local info = get_info(e.pid)
			return table.concat({
				"command: " .. e.command,
				"pid:     " .. e.pid,
				"ports:   " .. (e.ports),
				"user:    " .. e.user,
				"cmdline: " .. (info.cmdline or "?"),
				"cwd:     " .. (info.cwd or "?"),
				"uptime:  " .. (info.uptime or "?"),
			}, "\n")
		end,
	},
}

local function yank_menu(entry)
	vim.ui.select(COPY_OPTIONS, {
		prompt = "Copy as:",
		format_item = function(o)
			return o.name
		end,
	}, function(choice)
		if not choice then
			return
		end
		vim.fn.setreg("+", choice.fn(entry))
		vim.notify("Yanked to + register", vim.log.levels.INFO)
	end)
end

local function goto_source(entry)
	if entry.is_container then
		vim.notify("goto-source not wired for containers", vim.log.levels.WARN)
		return
	end
	local info = get_info(entry.pid)
	if not info.cmdline then
		vim.notify("No cmdline for PID " .. entry.pid, vim.log.levels.WARN)
		return
	end
	local exts = {
		"%.js$",
		"%.mjs$",
		"%.cjs$",
		"%.ts$",
		"%.tsx$",
		"%.jsx$",
		"%.py$",
		"%.rb$",
		"%.go$",
		"%.rs$",
		"%.php$",
		"%.lua$",
		"%.sh$",
	}
	local candidate
	for token in info.cmdline:gmatch("%S+") do
		for _, pat in ipairs(exts) do
			if token:match(pat) then
				candidate = token
				break
			end
		end
		if candidate then
			break
		end
	end
	if not candidate then
		vim.notify("No source file in cmdline", vim.log.levels.WARN)
		return
	end
	local path = candidate
	if not path:match("^/") and info.cwd then
		path = info.cwd .. "/" .. path
	end
	if vim.fn.filereadable(path) == 1 then
		vim.cmd("edit " .. vim.fn.fnameescape(path))
	else
		vim.notify("File not found: " .. path, vim.log.levels.WARN)
	end
end

----------------------------------------------------------------------
-- Picker
----------------------------------------------------------------------

local function with_entry(fn)
	return function(selected)
		local rows = selected_rows(selected)
		if #rows == 0 then
			return
		end
		fn(rows[1])
	end
end

function M.net_picker(opts)
	opts = opts or {}
	clear_caches()
	_runtime_cache = nil

	local lines = vim.fn.systemlist({ "lsof", "-i", "-P", "-n" })
	if #lines > 0 and lines[1]:match("^COMMAND") then
		table.remove(lines, 1)
	end

	local processes = dedupe_by_pid(lines)

	local containers_ok, containers_or_err = pcall(list_containers)
	local containers
	if containers_ok and type(containers_or_err) == "table" then
		containers = containers_or_err
	else
		containers = {}
		local msg = type(containers_or_err) == "table" and vim.inspect(containers_or_err) or tostring(containers_or_err)
		vim.notify("container enumeration failed: " .. msg, vim.log.levels.WARN)
	end

	if #processes == 0 and #containers == 0 then
		vim.notify("No network processes or containers found", vim.log.levels.WARN)
		return
	end

	processes = filter_container_helpers(processes, containers)

	local rows = build_rows(processes, containers)
	set_rows(rows)

	local items = {}
	for _, row in ipairs(rows) do
		items[#items + 1] = format_row(row) .. "\t" .. row.index
	end

	fzf.fzf_exec(items, {
		prompt = "Net> ",
		fzf_opts = {
			["--multi"] = true,
			["--delimiter"] = "\t",
			["--with-nth"] = "1",
			["--tiebreak"] = "index",
		},
		preview = log_preview,
		actions = {
			["enter"] = { fn = function(selected) do_kill(selected_rows(selected), "-TERM") end, header = "kill (SIGTERM)" },
			["ctrl-k"] = { fn = function(selected) do_kill(selected_rows(selected), "-TERM") end, header = "kill (SIGTERM)" },
			["ctrl-s"] = { fn = function(selected) signal_menu(selected_rows(selected)) end, header = "signal" },
			["ctrl-t"] = { fn = with_entry(tail_logs), header = "tail log" },
			["ctrl-r"] = { fn = with_entry(restart), header = "restart" },
			["ctrl-d"] = { fn = with_entry(debugger_menu), header = "debugger" },
			["ctrl-o"] = { fn = with_entry(open_project), header = "cd to cwd" },
			["ctrl-y"] = { fn = with_entry(yank_menu), header = "yank" },
			["ctrl-g"] = { fn = with_entry(goto_source), header = "goto source" },
		},
	})
end

return M

--- Module for persisting and loading session IDs across Neovim restarts
--- Sessions are stored per project (working directory)

local Logger = require("agentic.utils.logger")

--- @class agentic.utils.SessionPersistence
local SessionPersistence = {}

--- Get the cache directory for storing session data
--- @return string
function SessionPersistence.get_cache_dir()
    local cache_home = vim.fn.getenv("XDG_CACHE_HOME")
    if cache_home == vim.NIL or cache_home == "" then
        cache_home = vim.fn.expand("~/.cache")
    end

    local cache_dir = cache_home .. "/agentic.nvim"

    -- Create cache directory if it doesn't exist
    if vim.fn.isdirectory(cache_dir) == 0 then
        vim.fn.mkdir(cache_dir, "p")
    end

    return cache_dir
end

--- Get the session file path for the current working directory
--- @param cwd? string Optional working directory (defaults to vim.fn.getcwd())
--- @param provider_name? string Optional provider name to scope sessions per provider
--- @return string
function SessionPersistence.get_session_file_path(cwd, provider_name)
    cwd = cwd or vim.fn.getcwd()
    provider_name = provider_name or "default"

    -- Create a safe filename from the working directory path
    local safe_cwd = cwd:gsub("[^%w%-_]", "_")
    local filename = string.format("session_%s_%s.json", provider_name, safe_cwd)

    return SessionPersistence.get_cache_dir() .. "/" .. filename
end

--- Save session ID to disk
--- @param session_id string
--- @param cwd? string
--- @param provider_name? string
function SessionPersistence.save_session(session_id, cwd, provider_name)
    cwd = cwd or vim.fn.getcwd()
    provider_name = provider_name or "default"

    local file_path = SessionPersistence.get_session_file_path(cwd, provider_name)

    local data = {
        session_id = session_id,
        cwd = cwd,
        provider = provider_name,
        timestamp = os.time(),
    }

    local json = vim.json.encode(data)

    local file = io.open(file_path, "w")
    if not file then
        Logger.debug("Failed to save session to:", file_path)
        return
    end

    file:write(json)
    file:close()

    Logger.debug("Saved session:", session_id, "to", file_path)
end

--- Load session ID from disk
--- @param cwd? string
--- @param provider_name? string
--- @return string|nil session_id The session ID if found and valid
function SessionPersistence.load_session(cwd, provider_name)
    cwd = cwd or vim.fn.getcwd()
    provider_name = provider_name or "default"

    local file_path = SessionPersistence.get_session_file_path(cwd, provider_name)

    if vim.fn.filereadable(file_path) == 0 then
        Logger.debug("No session file found:", file_path)
        return nil
    end

    local file = io.open(file_path, "r")
    if not file then
        Logger.debug("Failed to open session file:", file_path)
        return nil
    end

    local content = file:read("*a")
    file:close()

    local ok, data = pcall(vim.json.decode, content)
    if not ok or not data or not data.session_id then
        Logger.debug("Invalid session file:", file_path)
        return nil
    end

    Logger.debug("Loaded session:", data.session_id, "from", file_path)
    return data.session_id
end

--- Delete session file from disk
--- @param cwd? string
--- @param provider_name? string
function SessionPersistence.delete_session(cwd, provider_name)
    cwd = cwd or vim.fn.getcwd()
    provider_name = provider_name or "default"

    local file_path = SessionPersistence.get_session_file_path(cwd, provider_name)

    if vim.fn.filereadable(file_path) == 1 then
        vim.fn.delete(file_path)
        Logger.debug("Deleted session file:", file_path)
    end
end

--- Clear all cached sessions
function SessionPersistence.clear_all_sessions()
    local cache_dir = SessionPersistence.get_cache_dir()
    local pattern = cache_dir .. "/session_*.json"

    local files = vim.fn.glob(pattern, false, true)
    for _, file in ipairs(files) do
        vim.fn.delete(file)
    end

    Logger.debug("Cleared all session files")
end

return SessionPersistence

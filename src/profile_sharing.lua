-- This is a profile_sharing policy.

local policy = require('apicast.policy')
local _M = policy.new('profile_sharing')

local setmetatable = setmetatable
local concat = table.concat
local insert = table.insert
local len = string.len
local format = string.format
local pairs = pairs
local sub = string.sub

local ts = require ('apicast.threescale_utils')
local redis = require('resty.redis')
local http_ng = require('resty.http_ng')
local http_ng_resty = require('resty.http_ng.backend.resty')
local user_agent = require('apicast.user_agent')
local resty_url = require('resty.url')
local resty_env = require('resty.env')
local cjson = require('cjson')
local inspect = require('inspect')

local new = _M.new

--- Utilities (local functions)
---
local function obtain_app_id(context)
  if not context then
    return nil
  end

  if context.credentials and context.credentials.app_id then
    return context.credentials.app_id
  end

  local service = context.service
  if not service then
    ngx.log(ngx.WARN, 'unable to find credentials nor service in context')
    return nil
  end

  local service_creds = service:extract_credentials()
  if not service_creds or
     not service_creds.app_id then
    return nil
  end

  return service_creds.app_id
end

local function build_url(self, path_and_params)
  local endpoint = self.base_url

  if not endpoint then
    return nil, 'missing endpoint'
  end

  return resty_url.join(endpoint, '', path_and_params)
end

-- Get the associated `account_id` using the `app_id` or `jwt.client_id` params from 3scale API.
local function application_find(self, app_id)
  local http_client = self.http_client
  if not http_client then
    return nil, 'http_client not initialized'
  end

  path = '/admin/api/applications/find.json?'
  local url = build_url(self, path .. 'app_id=' .. app_id .. '&access_token=' .. self.access_token)

  local res, err = http_client.get(url)

  if not res and err then
    ngx.log(ngx.DEBUG, 'application_find() get error: ', err, ' url: ', url)
    return nil
  end
  ngx.log(ngx.INFO, 'http client uri: ', url, ' ok: ', res.ok, ' status: ', res.status, ' body: ', res.body)

  if res.status == 200 and res.body and res.body ~= cjson.null then
    return cjson.decode(res.body)
  else
    return nil
  end
end

-- Get the extra_fields data for that account using the `accound_id` param from 3scale API.
local function accound_read(self, id)
  if not id or id == '' then
    return nil, 'app_id is empty'
  end

  local http_client = self.http_client
  if not http_client then
    return nil, 'not initialized'
  end

  path = '/admin/api/accounts/' .. id .. '.json?'
  local url = build_url(self, path .. 'access_token=' .. self.access_token)

  local res, err = http_client.get(url)
  if not res and err then
    ngx.log(ngx.DEBUG, 'application_find() get error: ', err, ' url: ', url)
    return nil
  end
  ngx.log(ngx.INFO, 'http client uri: ', url, ' ok: ', res.ok, ' status: ', res.status, ' body: ', res.body)

  if res.status == 200 and res.body and res.body ~= cjson.null then
    return cjson.decode(res.body)
  else
    return nil
  end
end

local function fetch_profile_from_backend(self, app_id)
  local app_response = application_find(self, app_id)

  if not app_response or
     app_response == cjson.null or
     not app_response.application or
     app_response.application == cjson.null then
    return nil
  end

  local accound_id = app_response.application.account_id or app_response.application.user_account_id
  if not accound_id then
    return nil
  end

  local acc_response = accound_read(self, accound_id)

  if not acc_response or
     acc_response == cjson.null or
     not acc_response.account or
     acc_response.account == cjson.null or
     not acc_response.account.id or
     acc_response.account.id == cjson.null then
    return nil
  end

  return acc_response.account, app_response.application.plan
end

local function set_request_header(header_name, value)
  ngx.req.set_header(header_name, value)
end

local function set_profile_headers(self, profile)
  set_request_header(self.header_keys.id, profile.id)
  set_request_header(self.header_keys.name, profile.name)
  set_request_header(self.header_keys.info, cjson.encode(profile.info))
  set_request_header(self.header_keys.plan_id, profile.plan_id)
  set_request_header(self.header_keys.plan_name, profile.plan_name)
end


--- Initialize a profile_sharing module
-- @tparam[opt] table config Policy configuration.
--
function _M.new(config)
  local self = new(config)

  -- define header keys to be used.
  self.header_keys = {
    id        = 'X-Api-Gateway-Account-Id',
    name      = 'X-Api-Gateway-Account-Name',
    info      = 'X-Api-Gateway-Account-Info',
    plan_id   = 'X-Api-Gateway-Account-Plan-Id',
    plan_name = 'X-Api-Gateway-Account-Plan-Name',
  }

  -- load environment variables for admin APIs access.
  self.base_url     = resty_env.value("THREESCALE_ADMIN_API_URL") or ''
  self.access_token = resty_env.value("THREESCALE_ADMIN_API_ACCESS_TOKEN") or ''

  self.cache_key_prefix = 'elm-customer-'

  -- build local http client, or used pre-defined one (if injected).
  local client = http_ng.new {
    backend = config and config.backend or http_ng_resty,
    options = {
      headers = {
        host = base_url,
        user_agent = user_agent()
      },
      ssl = { verify = resty_env.enabled('OPENSSL_VERIFY') }
    }
  }
  self.http_client = client

  return self
end

--- Rewrite phase: add profile-share info before content phase done by upstream/backend.
---
function _M:rewrite(context)
  local app_id = obtain_app_id(context)

  if not app_id then
    ngx.log(ngx.DEBUG, 'app_id not found in context.')
    return
  end
  ngx.log(ngx.DEBUG, 'app_id is assigned from context: ', app_id)

  -- Assign the cahce key with app_id and prefix.
  local cache_key = self.cache_key_prefix .. tostring(app_id)

  -- Use redis for reading from cache first.
  local redis, err = self.safe_connect_redis()
  if not redis then
    ngx.log(ngx.WARN, 'cannot connect to redis instance, error:', inspect(err))
  else
    local cached_data = redis:get(cache_key)
    ngx.log(ngx.INFO, 'account data found in cache: ', cjson.encode(cached_data))
    if cached_data and cached_data ~= nil and type(cached_data) == 'string' then
      local cached_profile = cjson.decode(cached_data)

      if cached_profile and cached_profile ~= nil then
        set_profile_headers(self, cached_profile)
        return
      end
    end
  end

  -- Otherwise, fall back to APIs.
  local account, plan = fetch_profile_from_backend(self, app_id)
  if not account then
    ngx.log(ngx.WARN, 'account information is not found in the system. app_id = ' .. app_id)
    return
  end

  local profile = {
    id = account.id,
    name = account.org_name,
    info = account.organization_number or account.extra_fields,
    plan_id = nil,
    plan_name = nil
  }

  if plan then
    profile.plan_id = plan.id
    profile.plan_name = plan.name
  end

  -- Cache profile info into redis by app-id as the cache key, value is the profile table.
  if redis then
    redis:set(cache_key, cjson.encode(profile))
  end

  -- Change the request before it reaches upstream or backend.
  set_profile_headers(self, profile)
end

function _M.safe_connect_redis(options)
  local opts = {}
  local url = options and options.url or resty_env.get('REDIS_URL')
  local redis_conf = {
    timeout   = 3000,  -- 3 seconds
    keepalive = 10000, -- milliseconds
    poolsize  = 1000   -- # connections
  }

  if url then
    url = resty_url.split(url, 'redis')
    if url then
      opts.host = url[4]
      opts.port = url[5]
      opts.db = url[6] and tonumber(sub(url[6], 2))
      opts.password = url[3] or url[2]
    end
  elseif options then
    opts.host = options.host
    opts.port = options.port
    opts.db = options.db
    opts.password = options.password
  end

  opts.timeout = options and options.timeout or redis_conf.timeout

  local host = opts.host or resty_env.get('REDIS_HOST') or "127.0.0.1"
  local port = opts.port or resty_env.get('REDIS_PORT') or 6379

  local red = redis:new()

  red:set_timeout(opts.timeout)

  local ok, err = red:connect(ts.resolve(host, port))
  if not ok then
    ngx.log(ngx.WARN, "failed to connect to redis on ", host, ":", port, ": ", err)
    return nil
  end

  if opts.password then
    ok = red:auth(opts.password)

    if not ok then
      ngx.log(ngx.WARN, "failed to auth on redis ", host, ":", port)
      return nil
    end
  end

  if opts.db then
    ok = red:select(opts.db)

    if not ok then
      ngx.log(ngx.WARN, "failed to select db ", opts.db, " on redis ", host, ":", port)
      return nil
    end
  end

  return red
end

return _M

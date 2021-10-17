-- This is a profile_sharing policy.

local policy = require('apicast.policy')
local _M = policy.new('profile_sharing')

local setmetatable = setmetatable
local concat = table.concat
local insert = table.insert
local len = string.len
local format = string.format
local pairs = pairs

local ts = require ('apicast.threescale_utils')
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
  if not context or
     not context.credentials or
     not context.credentials.app_id then
    return nil
  end

  return context.credentials.app_id
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

  if res.status == 200 and res.body then
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

  if res.status == 200 and res.body then
    return cjson.decode(res.body)
  else
    return nil
  end
end

local function fetch_profile_from_backend(self, app_id)
  local app_response = application_find(self, app_id)
  if not app_response or
     not app_response.application or
     not app_response.application.user_account_id then
    return nil
  end

  local acc_response = accound_read(self, app_response.application.user_account_id)
  if not acc_response or
     not acc_response.account or
     not acc_response.account.id then
    return nil
  end

  return acc_response.account
end

local function set_request_header(header_name, value)
  ngx.req.set_header(header_name, value)
end

local function set_profile_headers(self, profile)
  set_request_header(self.header_keys.id, profile.id)
  set_request_header(self.header_keys.name, profile.name)
  set_request_header(self.header_keys.info, cjson.encode(profile.info))
end

--- Initialize a profile_sharing module
-- @tparam[opt] table config Policy configuration.
--
function _M.new(config)
  local self = new(config)

  -- define header keys to be used.
  self.header_keys = {
    id   = 'X-Api-Gateway-Account-Id',
    name = 'X-Api-Gateway-Account-Name',
    info = 'X-Api-Gateway-Account-Info'
  }

  -- load environment variables for admin APIs access.
  self.base_url     = resty_env.value("THREESCALE_ADMIN_API_URL") or ''
  self.access_token = resty_env.value("THREESCALE_ADMIN_API_ACCESS_TOKEN") or ''

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
    return
  end

  -- Use redis for reading from cache first.
  local redis = ts.connect_redis()
  if redis then
    local cached_profile_data = redis.get(app_id)

    local cached_profile = cjson.decode(cached_profile)

    if cached_profile then
      set_profile_headers(self, cached_profile)
      return
    end
  end

  -- Otherwise, fall back to APIs.
  local account = fetch_profile_from_backend(self, app_id)
  if not account then
    ngx.log(ngx.WARN, 'account information is not found in system. app_id = ' .. app_id)
    return
  end

  local profile = {
    id = account.id,
    name = account.org_name,
    info = account.extra_fields
  }

  -- Cache profile info into redis by app-id as the cache key, value is the profile table.
  if redis then
    red.set(app_id, cjson.encode(profile))
  end

  -- Change the request before it reaches upstream or backend.
  set_profile_headers(self, profile)
end


return _M

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
local user_agent = require('apicast.user_agent')
local resty_url = require('resty.url')
local resty_env = require('resty.env')
local cjson = require('cjson')

local new = _M.new

--- utilities (local functions)
---
local function obtain_app_id()
  if context and context.credentials and context.credentials.app_id then
    return context.credentials.app_id
  end
  return nil
end

local function application_find(app_id)
  --- Get the associated `account_id` using the `app_id` or `jwt.client_id` params from 3scale API.
  --
  local http_client = self.http_client
  if not http_client then
    return nil, 'http_client not initialized'
  end

  path = '/admin/api/applications/find.json'
  local url = build_url(self, path, { app_id = app_id, access_token = self.access_token })
  local res = http_client.get(url, options)

  ngx.log(ngx.INFO, 'http client uri: ', url, ' ok: ', res.ok, ' status: ',
          res.status, ' body: ', res.body, ' error: ', res.error)

  if res.status == 200 and res.body then
    return cjson.decode(res.body)
  else
    return nil
  end
end

local function accound_read(id)
  --- Get the extra_fields data for that account using the `accound_id` param from 3scale API.
  --
  if not id or id == '' then
    return nil, 'app_id is empty'
  end

  local http_client = self.http_client
  if not http_client then
    return nil, 'not initialized'
  end

  path = '/admin/api/accounts/' .. id .. '.json'
  local url = build_url(self, path, { app_id = app_id, access_token = self.access_token })
  local res = http_client.get(url, options)

  ngx.log(ngx.INFO, 'http client uri: ', url, ' ok: ', res.ok, ' status: ',
          res.status, ' body: ', res.body, ' error: ', res.error)

end

local function build_url(self, path, ...)
  local endpoint = self.base_url

  if not endpoint then
    return nil, 'missing endpoint'
  end

  return resty_url.join(endpoint, '', path .. '?' .. build_args(...))
end

local function build_args(args)
  local query = {}

  for i=1, #args do
    local arg = ngx.encode_args(args[i])
    if len(arg) > 0 then
      insert(query, arg)
    end
  end

  return concat(query, '&')
end

local function set_profile_headers(profile)
  set_request_header('X-Api-Gateway-Account-Id', profile.id)
  set_request_header('X-Api-Gateway-Account-Info', cjson.encode(profile.info))
end

local function set_request_header(header_name, value)
  ngx.req.set_header(header_name, value)
end


--- Initialize a profile_sharing module
-- @tparam[opt] table config Policy configuration.
--
function _M.new(config)
  local self = new(config)

  self.base_url     = resty_env.value("THREESCALE_ADMIN_API_URL") or ''
  self.access_token = resty_env.value("THREESCALE_ADMIN_API_ACCESS_TOKEN") or ''

  -- build local http client
  local client = http_ng.new {
    backend = http_ng,
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
function _M:rewrite()
  local app_id = obtain_app_id()
  if not app_id then
    return
  end

  local red = ts.connect_redis()

  -- Use redis for reading from cache first.
  local cached_profile = red.get(app_id)
  if cached_profile then
    set_profile_headers(cached_profile)
    return
  end

  -- Otherwise, fall back to APIs.
  local account = fetch_profile_from_backend(app_id)
  if not account then
    return
  end

  local profile = {
    id = account.id,
    info = account.extra_fields
  }
  -- Cache profile info into redis by app-id as the cache key, value is the profile table.
  red.set(app_id, profile)

  -- Change the request before it reaches upstream or backend.
  set_profile_headers(profile)
end

local function fetch_profile_from_backend(app_id)
  local app_response = application_find(app_id)

  if not app_response or
     not app_response.application or
     not app_response.application.user_account_id then
    return nil
  end

  local acc_response = accound_read(accound_id)
  if not acc_response or
     not acc_response.account or
     not acc_response.account.id then
    return nil
  end

  return acc_response.account
end

return _M

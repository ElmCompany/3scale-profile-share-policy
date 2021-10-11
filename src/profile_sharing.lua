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

--- Initialize a profile_sharing
-- @tparam[opt] table config Policy configuration.
function _M.new(config)
  local self = new(config)

  self.base_url     = resty_env.value("3SCALE_ADMIN_API_URL") or ''
  self.access_token = resty_env.value("3SCALE_ADMIN_API_ACCESS_TOKEN") or ''

  -- build local http client
  local client = http_ng.new{
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

function _M:rewrite()
  local app_id = obtain_app_id()
  if not app_id then
    return
  end

  -- TODO: Use redis for reading from cache first.
  local red = ts.connect_redis()

  local result = red.get(app_id)
  if result then
    return result
  end

  -- Otherwise, fall back to APIs.
  local account_id = application_find(app_id).application.user_account_id
  local account_data = accound_read(accound_id)

  local profile = {
    id = account_data.account.id,
    info = account_data.account.extra_fields
  }

  -- TODO: cache profile info into redis by app-id as the cache key, value is the profile table.

  -- change the request before it reaches upstream or backend.
  -- This is here to avoid calling ngx.req.get_headers() in every command
  -- applied to the request headers.
  local req_headers = ngx.req.get_headers() or {}
  set_request_header('X-Account-Id', profile.id)
  set_request_header('X-Account-Info', cjson.encode(profile.info))
end


--- Get the associated `account_id` using the `app_id` or `jwt.client_id` params from 3scale API.
local function application_find(app_id)
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

--- Get the extra_fields data for that account using the `accound_id` param from 3scale API.
local function accound_read(id)
  if not id then
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

  if res.status == 200 and res.body then
    return cjson.decode(res.body)
  else
    return nil
  end
end

--- utilities
---
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

local function obtain_app_id()
  return context.credentials.app_id
end

local function set_request_header(header_name, value)
  ngx.req.set_header(header_name, value)
end


return _M

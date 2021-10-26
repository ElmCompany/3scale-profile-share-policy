local _M = require 'apicast.policy.profile_sharing'
local test_backend_client = require 'resty.http_ng.backend.test'
local resty_env = require 'resty.env'
local cjson = require 'cjson'
local user_agent = require 'apicast.user_agent'
local env = require 'resty.env'
local ts = require 'apicast.threescale_utils'

local format = string.format
local encode_args = ngx.encode_args

describe('profile_sharing policy', function()

  describe('.new', function()
    it('works without configuration', function()
      assert(_M.new())
    end)

    it('accepts configuration', function()
      assert(_M.new({ }))
    end)

    it('reads base url and access token from environment variables', function ()
      stub(resty_env, 'value')

      m = _M.new()

      assert.stub(resty_env.value).was.called_with('THREESCALE_ADMIN_API_URL')
      assert.stub(resty_env.value).was.called_with('THREESCALE_ADMIN_API_ACCESS_TOKEN')
    end)

    it('falls resillently if cannot read base url and access token from environment variables', function()
      m = _M.new()
      assert.equals(m.base_url, '')
      assert.equals(m.access_token, '')
    end)

    it('builds an http client for communicating with APIs', function()
      m = _M.new()
      assert.is.not_false(m.http_client)
    end)
  end)

  describe(':rewrite phase', function ()
    local module
    before_each(function() module = _M.new() end)

    it ('exits safely if no app_id is found in context', function ()
      assert.equals(module:rewrite(), nil)
    end)

    it ('obtains app_id from service if not in context already', function ()
      local mocked_service = { service = {
        extract_credentials = function ()
          return { app_id = '324', app_key = 'lnk434rg24gw' }
        end
      } }
      stub(mocked_service.service, 'extract_credentials')

      module:rewrite(mocked_service)
      assert.spy(mocked_service.service.extract_credentials).was_called()
    end)
  end)

  local function stub_ngx_request()
    ngx.var = { }

    stub(ngx, 'exec')
    stub(ngx.req, 'set_header')
    stub(ngx.req, 'set_uri', function(uri)
        ngx.var.uri = uri
    end)
    stub(ngx.req, 'set_uri_args', function(args)
        ngx.var.args = args
        ngx.var.query_string = args
    end)
  end

  describe(':rewrite phase - API calls', function ()
    local test_backend
    local module
    local base_url = 'https://example.com'
    local token = '2qew5yrthfr'

    before_each(function ()
      resty_env.set('THREESCALE_ADMIN_API_URL', base_url)
      resty_env.set('THREESCALE_ADMIN_API_ACCESS_TOKEN', token)
    end)

    before_each(function()
      stub_ngx_request()

      test_backend = test_backend_client.new()
      module = _M.new({ backend = test_backend })
    end)

    it ('assigns http_client correctly', function ()
      assert.truthy(module.http_client)
      assert.truthy(module.http_client.backend)
      assert.equals(module.http_client.backend, test_backend)
    end)

    it ('loads account data given its id successfully', function ()
      test_backend.expect{ url = base_url .. '/admin/api/applications/find.json?app_id=2&access_token=' .. token }.
      respond_with { status = 200, body = cjson.encode(
        {
          application = {
            id = '2',
            created_at = '2021-09-15T08:54:58Z',
            updated_at = '2021-09-15T08:54:58Z',
            state = 'live',
            user_account_id = 2445,
            first_traffic_at = cjson.null
          }
        }
      )}

      test_backend.expect{ url = base_url .. '/admin/api/accounts/2445.json?access_token=' .. token }.
      respond_with { status = 200, body = cjson.encode(
        {
          account = {
            id = 2445583835853,
            created_at = '2021-09-16T10:37:50+10:00',
            updated_at = '2021-09-16T10:37:50+10:00',
            state = 'created',
            org_name = 'test',
            city = 'test001',
            country = 'Australia',
            extra_fields = {
              moi_number = 1234
            },
            monthly_billing_enabled = true,
            monthly_charging_enabled = true,
            credit_card_stored = false,
            plans = {},
            users = {}
          }
        })
      }

      module:rewrite({ credentials = { app_id = 2 } })

      assert.spy(ngx.req.set_header).was_called_with(module.header_keys.id, 2445583835853)
      assert.spy(ngx.req.set_header).was_called_with(module.header_keys.name, 'test')
      assert.spy(ngx.req.set_header).was_called_with(module.header_keys.info, cjson.encode(
        { moi_number = 1234 }
      ))
    end)

    it ('fails resillently when find-application API data is not found or reachabled', function ()
      local random_status = ({ 200, 404, 400, 503 })[math.random(1, 4)]
      local random_body = ({ nil, cjson.encode({}), cjson.encode({ application = cjson.null }) })[math.random(1, 3)]

      test_backend.expect{ url = base_url .. '/admin/api/applications/find.json?app_id=2&access_token=' .. token }.
      respond_with { status = random_status, body = random_body }

      module:rewrite({ credentials = { app_id = 2 } })

      assert.spy(ngx.req.set_header).was_not_called()
      assert.spy(ngx.req.set_header).was_not_called()
      assert.spy(ngx.req.set_header).was_not_called()
    end)

    it ('fails resillently when read-account API data is not found or reachabled', function ()
      test_backend.expect{ url = base_url .. '/admin/api/applications/find.json?app_id=2&access_token=' .. token }.
      respond_with { status = 200, body = cjson.encode(
        {
          application = {
            id = '2',
            created_at = '2021-09-15T08:54:58Z',
            updated_at = '2021-09-15T08:54:58Z',
            state = 'live',
            user_account_id = 2445,
            first_traffic_at = cjson.null
          }
        }
      )}

      test_backend.expect{ url = base_url .. '/admin/api/accounts/2445.json?access_token=' .. token }.
      respond_with { status = 200, body = cjson.encode(
        {
          account = { }
        })
      }

      module:rewrite({ credentials = { app_id = 2 } })

      assert.spy(ngx.req.set_header).was_not_called()
      assert.spy(ngx.req.set_header).was_not_called()
      assert.spy(ngx.req.set_header).was_not_called()
    end)
  end)

  describe(':rewrite phase - Caching', function ()
    local module

    local function stub_redis()
      stub(module, 'safe_connect_redis', function(opts)
        return {
          get = function (key)
            local result = cjson.encode({
              id = 5,
              name = 'TSD Team',
              info = { moi_number = 000 }
            })
            return result
          end,
          set = function (key, value)
            local fake_cache = {}
            fake_cache[key] = value
            return
          end
        }
      end)
    end

    before_each(function() module = _M.new() end)
    before_each(function()
      stub_ngx_request()
      stub_redis()
    end)

    it ('reads the profile from cache successfully', function ()
      local redis = module:safe_connect_redis()

      local cache_key = '5'
      local cache_value = cjson.encode({
        id = 5,
        name = 'TSD Team',
        info = { moi_number = 000 }
      })

      redis:set(cache_key, cache_value)

      module:rewrite({ credentials = { app_id = 5 } })

      assert.spy(ngx.req.set_header).was_called_with(module.header_keys.id, 5)
      assert.spy(ngx.req.set_header).was_called_with(module.header_keys.name, 'TSD Team')
      assert.spy(ngx.req.set_header).was_called_with(module.header_keys.info, cjson.encode(
        { moi_number = 000 }
      ))
    end)

    it ('sets the profile to the cache successfully', function ()
    end)
  end)

  describe(':rewrite phase - Headers', function ()
    local module
    local test_backend
    local base_url = 'https://3scale-dev.apps.elm.com'
    local token = '238ivd'

    before_each(function ()
      resty_env.set('THREESCALE_ADMIN_API_URL', base_url)
      resty_env.set('THREESCALE_ADMIN_API_ACCESS_TOKEN', token)
    end)

    before_each(function()
      stub_ngx_request()

      test_backend = test_backend_client.new()
      module = _M.new({ backend = test_backend })
    end)

    it ('assigns the profile headers succesfully', function ()
      test_backend.expect{ url = base_url .. '/admin/api/applications/find.json?app_id=3942&access_token=' .. token }.
      respond_with { status = 200, body = cjson.encode(
        {
          application = {
            id = '144',
            created_at = '2021-09-15T08:54:58Z',
            updated_at = '2021-09-15T08:54:58Z',
            state = 'live',
            user_account_id = 1000,
            first_traffic_at = cjson.null
          }
        }
      )}

      test_backend.expect{ url = base_url .. '/admin/api/accounts/1000.json?access_token=' .. token }.
      respond_with { status = 200, body = cjson.encode(
        {
          account = {
            id = 1000,
            created_at = '2021-09-16T10:37:50+10:00',
            updated_at = '2021-09-16T10:37:50+10:00',
            state = 'created',
            org_name = 'Elm Company',
            city = 'test001',
            country = 'Australia',
            extra_fields = {
              moi_number = 70044038
            },
            monthly_billing_enabled = true,
            monthly_charging_enabled = true,
            credit_card_stored = false,
            plans = {},
            users = {}
          }
        })
      }

      module:rewrite({ credentials = { app_id = 3942 } })

      assert.spy(ngx.req.set_header).was_called_with(module.header_keys.id, 1000)
      assert.spy(ngx.req.set_header).was_called_with(module.header_keys.name, 'Elm Company')
      assert.spy(ngx.req.set_header).was_called_with(module.header_keys.info, cjson.encode(
        { moi_number = 70044038 }
      ))
    end)
  end)
end)

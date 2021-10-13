local _M = require('apicast.policy.profile_sharing')
local resty_env = require('resty.env')

describe('profile_sharing policy', function()

  describe('.new', function()
    it('works without configuration', function()
      assert(_M.new())
    end)

    it('accepts configuration', function()
      assert(_M.new({ }))
    end)

    it('reads base url and access token from environment variables', function ()
      local url = 'https://3scale-admin.dev-apps.elm.sa'
      local token = '94035titj5gfpo'

      stub(resty_env, 'value')

      m = _M.new()

      assert.stub(resty_env.value).was.called_with("THREESCALE_ADMIN_API_URL")
      assert.stub(resty_env.value).was.called_with("THREESCALE_ADMIN_API_ACCESS_TOKEN")
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

  describe('.rewrite', function ()
    local module
    before_each(function() module = _M.new() end)

    it ('exits safely if no app_id is found in context', function ()
      assert.equals(module.rewrite(), nil)
    end)

    it ('loads account data given its id successfully', function ()
    end)
  end)
end)

local _M = require('apicast.policy.profile_sharing')

describe('profile_sharing policy', function()

  describe('.new', function()
    it('works without configuration', function()
      assert(_M.new())
    end)

    it('accepts configuration', function()
      assert(_M.new({ }))
    end)

    it('reads base url and access token from environment variables resillently', function()
      m = _M.new()
      assert.equals(m.base_url, '')
      assert.equals(m.access_token, '')
    end)

    it('builds an http client for communicating with APIs', function()
      m = _M.new()
      assert.is.not_false(m.http_client)
    end)
  end)

  describe('.find_account', function ()
    it ('loads account data given its id', function ()
    end)
  end)
end)

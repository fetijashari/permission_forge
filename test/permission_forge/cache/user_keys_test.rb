# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Cache
    # Cache::UserKeys: the one definition of a user's keys. Since 0.15 an
    # invalidation removes this version's entries only: the bare keys of
    # 0.13 (`user_<id>`, `tenant_<t>_user_<id>`), removed by every
    # invalidation through 0.14, are no longer the gem's.
    class UserKeysTest < ActiveSupport::TestCase
      test 'an invalidation names the stamp and the v2 keys, and no bare key of 0.13' do
        target = UserKeys.invalidation(7, tenant_id: 3, ambient_key: UserKeys.hash_key(7, nil))

        assert_equal 'user_7_invalidation', target[:stamp_key]
        assert_equal %w[v2:user_7 v2:tenant_3_user_7], target[:keys]
        assert_empty target[:keys].grep(/\A(?:tenant_\d+_)?user_7\z/), 'no bare key'
      end

      test 'the entries live under one namespace, the previous ones are gone' do
        assert_equal 'v2', UserKeys::ENTRY_NAMESPACE
        assert_empty UserKeys::PREVIOUS_ENTRY_NAMESPACES
        assert_equal ['v2'], UserKeys.namespaces
      end

      test 'a cache:clear by pattern reaches the v2 entries only' do
        regexp, globs = UserKeys.entry_patterns(UserKeys::ENTRY_NAMESPACE, prefix: 'pf')

        assert_match regexp, 'pf:v2:user_7'
        assert_match regexp, 'pf:v2:tenant_3_user_7'
        assert_no_match regexp, 'pf:user_7'
        assert_equal %w[pf:v2:user_* pf:v2:tenant_*_user_*], globs
      end
    end
  end
end

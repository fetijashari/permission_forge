# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # The value object behind per-context permission hashes: what the base
  # entry carries about a user's conditional sets, which of them a request
  # context selects, and the variant key that selection names.
  class ConditionalSetsTest < ActiveSupport::TestCase
    setup do
      @plain = create_permission_set(name: 'Plain')
      @mfa = create_permission_set(name: 'MFA', requires_session_flag: 'mfa_verified')
      @office = create_permission_set(name: 'Office', allowed_ips: '10.0.0.0/8')
      @lockdown = create_permission_set(name: 'Lockdown', is_muting: true, allowed_hours_start: 22, allowed_hours_end: 6)
      @sets = [@plain, @mfa, @office, @lockdown]
    end

    teardown do
      PermissionForge.configuration.conditional_sets_strict_mode = false
    end

    # --- of / split / dump ----------------------------------------------------------

    test 'of: nil when no set is conditional, else the conditional ones with their conditions' do
      assert_nil ConditionalSets.of([@plain])

      conditional = ConditionalSets.of(@sets)
      assert_equal [@mfa.id, @office.id, @lockdown.id], conditional.sets.map(&:id)
      assert_equal [false, false, true], conditional.sets.map(&:muting?)
      assert_equal ['mfa_verified', nil, nil], conditional.sets.map(&:requires_session_flag)
      assert_equal [nil, '10.0.0.0/8', nil], conditional.sets.map(&:allowed_ips)
      assert_equal([[nil, nil], [nil, nil], [22, 6]], conditional.sets.map { |m| [m.allowed_hours_start, m.allowed_hours_end] })
      assert_match(/\A\h{16}\z/, conditional.token)
    end

    test 'dump is plain data (symbol keys, no objects) and split reads it back from an entry' do
      conditional = ConditionalSets.of(@sets)
      data = conditional.dump
      assert_equal %i[token sets], data.keys
      assert_equal %i[id muting requires_session_flag allowed_ips allowed_hours_start allowed_hours_end], data[:sets].first.keys
      assert(data[:sets].flat_map(&:values).all? { |v| [NilClass, Integer, String, TrueClass, FalseClass].include?(v.class) })

      entry = { profile: {}, preferences: {}, permissions: { resources: {} }, conditional_sets: data }
      hash, loaded = ConditionalSets.split(entry)
      assert_equal %i[profile preferences permissions], hash.keys
      assert_equal %i[profile preferences permissions conditional_sets], entry.keys, 'the entry is left alone'
      assert_equal conditional.token, loaded.token
      assert_equal conditional.sets, loaded.sets
    end

    test 'split leaves an entry without conditional sets untouched (the same object) and answers no sets' do
      entry = { profile: {}, preferences: {}, permissions: { resources: {} } }

      hash, loaded = ConditionalSets.split(entry)

      assert_same entry, hash
      assert_nil loaded
    end

    test 'a stored member missing a condition (written by another version) loads with nil for it' do
      loaded = ConditionalSets.load(token: 'abcd', sets: [{ id: 7, muting: false, requires_session_flag: 'x' }])

      assert_equal [7], loaded.sets.map(&:id)
      assert_nil loaded.sets.first.allowed_ips
    end

    test 'load refuses conditional sets without a token, and split makes no entry of them' do
      assert_raises(ArgumentError) { ConditionalSets.load(sets: [{ id: 7 }]) }
      assert_raises(ArgumentError) { ConditionalSets.load(token: '', sets: []) }
      assert_raises(ArgumentError) { ConditionalSets.load(token: 'abcd', sets: ['7']) }

      base = { profile: {}, preferences: {}, permissions: { resources: {} } }
      assert_nil ConditionalSets.split(base.merge(conditional_sets: { sets: [{ id: 7 }] }))
      assert_nil ConditionalSets.split(base.merge(conditional_sets: 'junk'))
      assert_nil ConditionalSets.split(base.merge(conditional_sets: { token: 'abcd', sets: [7] }))
    end

    # --- variant ----------------------------------------------------------------------

    test 'variant: the passing sets by id, in order, under a fingerprint; nil when none passes' do
      conditional = ConditionalSets.of(@sets)

      both = conditional.variant(session_flags: ['mfa_verified'], ip: '10.1.1.1', time: Time.current.change(hour: 12))
      assert_equal [@mfa.id, @office.id].sort, both.ids
      assert_match(/\A\h{32}\z/, both.fingerprint)

      mfa_only = conditional.variant(session_flags: ['mfa_verified'], ip: '203.0.113.1', time: Time.current.change(hour: 12))
      assert_equal [@mfa.id], mfa_only.ids
      refute_equal both.fingerprint, mfa_only.fingerprint

      assert_nil conditional.variant(session_flags: [], ip: '203.0.113.1', time: Time.current.change(hour: 12))
    end

    test 'the fingerprint is stable for the same ids and differs between base entries (tokens)' do
      context = { session_flags: ['mfa_verified'], ip: '203.0.113.1', time: Time.current.change(hour: 12) }
      first = ConditionalSets.of(@sets)
      again = ConditionalSets.load(first.dump)

      assert_equal first.variant(context).fingerprint, again.variant(context).fingerprint
      refute_equal first.variant(context).fingerprint, ConditionalSets.of(@sets).variant(context).fingerprint
    end

    test 'a muting set that passes is part of the variant' do
      conditional = ConditionalSets.of(@sets)

      variant = conditional.variant(session_flags: [], ip: '203.0.113.1', time: Time.current.change(hour: 23))

      assert_equal [@lockdown.id], variant.ids
    end

    test 'a blank context: every conditional set passes, in strict mode only the muting ones' do
      conditional = ConditionalSets.of(@sets)

      assert_equal [@mfa.id, @office.id, @lockdown.id].sort, conditional.variant({}).ids
      assert_equal [@mfa.id, @office.id, @lockdown.id].sort, conditional.variant(nil).ids

      PermissionForge.configuration.conditional_sets_strict_mode = true
      assert_equal [@lockdown.id], conditional.variant({}).ids
      assert_nil ConditionalSets.of([@plain, @mfa]).variant({}), 'granting sets only: the base applies'
    end

    # --- select -----------------------------------------------------------------------

    test 'build_sets: the unconditional sets for the base, plus the sets of the variant' do
      conditional = ConditionalSets.of(@sets)
      variant = conditional.variant(session_flags: ['mfa_verified'], ip: '203.0.113.1', time: Time.current.change(hour: 12))

      assert_equal [@plain], ConditionalSets.build_sets(@sets, nil)
      assert_equal [@plain, @mfa], ConditionalSets.build_sets(@sets, variant)
    end

    # --- slots, variant entries, cacheable? (Q9) ------------------------------------------

    # A variant is stored in a slot of the base key — the bitmask of its sets
    # among the user's conditional sets, sorted by id — so a base key has a
    # fixed set of variant keys whatever its token, and erasure can name
    # every one of them (.variant_keys).
    test 'a variant is stored in the slot its sets make among the conditional sets, sorted by id' do
      conditional = ConditionalSets.of(@sets)
      noon = Time.current.change(hour: 12)
      both = conditional.serve(session_flags: ['mfa_verified'], ip: '10.0.0.1', time: noon)
      office = conditional.serve(session_flags: [], ip: '10.0.0.1', time: noon)

      assert_equal [@mfa.id, @office.id], both.variant.ids
      assert_equal 'user_1_c_3', both.store_key('user_1'), 'mfa (bit 0) and office (bit 1)'
      assert_equal 'user_1_c_2', office.store_key('user_1')
      reversed = ConditionalSets.of(@sets.reverse).serve(session_flags: ['mfa_verified'], ip: '10.0.0.1', time: noon)
      assert_equal both.store_key('user_1'), reversed.store_key('user_1'), 'the order the sets were read in does not matter'
      assert_includes ConditionalSets.variant_keys('user_1'), both.store_key('user_1')
      assert conditional.cacheable?
    end

    test 'variant_keys: every slot a base key has (2^MAX_CACHED_SETS - 1), whatever the token; not the index entry' do
      keys = ConditionalSets.variant_keys('user_1')

      assert_equal (2**ConditionalSets::MAX_CACHED_SETS) - 1, keys.size
      assert_equal keys.uniq, keys
      assert_equal %w[user_1_c_1 user_1_c_63], [keys.first, keys.last]
      assert_equal 'user_1_c_index', ConditionalSets.index_key('user_1')
      assert_not_includes keys, ConditionalSets.index_key('user_1')
      noon = Time.current.change(hour: 12)
      tokens = Array.new(2) { ConditionalSets.of(@sets).serve(session_flags: ['mfa_verified'], ip: '10.0.0.1', time: noon) }
      assert_equal tokens.first.store_key('user_1'), tokens.last.store_key('user_1'), 'another base, the same slot'
      assert_not_equal tokens.first.variant.fingerprint, tokens.last.variant.fingerprint
    end

    # The check that was the key's digest is in the entry: a variant serves
    # only the base (token) and the selection it was built for.
    test 'a stored variant carries the digest of its base and selection; anything else in its slot is no variant' do
      noon = Time.current.change(hour: 12)
      context = { session_flags: ['mfa_verified'], ip: '203.0.113.1', time: noon }
      conditional = ConditionalSets.of(@sets)
      variant = conditional.serve(context).variant
      hash = { profile: { id: 1 }, preferences: {}, permissions: { resources: {} } }

      entry = ConditionalSets.variant_entry(hash, variant)
      assert_equal %i[profile preferences permissions variant_of], entry.keys
      assert_equal variant.fingerprint, entry[ConditionalSets::VARIANT_KEY]
      assert_equal hash, ConditionalSets.variant_hash(entry, variant)
      assert_equal %i[profile preferences permissions], ConditionalSets.variant_hash(entry, variant).keys

      another_base = ConditionalSets.of(@sets).serve(context).variant
      assert_nil ConditionalSets.variant_hash(entry, another_base), 'the variant of a base that is gone'
      another_selection = conditional.serve(context.merge(ip: '10.0.0.1')).variant
      assert_nil ConditionalSets.variant_hash(entry, another_selection)
      assert_nil ConditionalSets.variant_hash(hash, variant), 'an entry without the digest (an earlier build)'
      assert_nil ConditionalSets.variant_hash(hash.merge(variant_of: nil), variant)
      assert_nil ConditionalSets.variant_hash(nil, variant)
    end

    test 'above MAX_CACHED_SETS the variants are not cached' do
      many = (ConditionalSets::MAX_CACHED_SETS + 1).times.map { |i| create_permission_set(name: "C#{i}", requires_session_flag: "f#{i}") }
      conditional = ConditionalSets.of(many)

      assert_not conditional.cacheable?
      assert_not conditional.variant(session_flags: ['f3']).cached
      assert_equal 1, conditional.variant(session_flags: ['f3']).ids.size, 'selected all the same'
    end

    # --- no_context? / clocked -----------------------------------------------------------

    test 'no_context?: nothing, or neither an IP nor session flags — the time alone is not a request context' do
      assert ConditionalSets.no_context?(nil)
      assert ConditionalSets.no_context?({})
      assert ConditionalSets.no_context?(ip: nil, session_flags: [], time: Time.current)
      assert ConditionalSets.no_context?(time: Time.current)
      assert_not ConditionalSets.no_context?(ip: '10.0.0.1')
      assert_not ConditionalSets.no_context?(session_flags: ['mfa_verified'])
    end

    test 'clocked: the time is fixed once, a given time is kept, nothing is added to a blank context' do
      travel_to Time.zone.local(2026, 10, 13, 16, 59, 59) do
        assert_equal Time.current, ConditionalSets.clocked(ip: '1.2.3.4')[:time]
      end
      noon = Time.current.change(hour: 12)
      assert_equal noon, ConditionalSets.clocked(ip: '1.2.3.4', time: noon)[:time]
      assert_equal({}, ConditionalSets.clocked({}))
      assert_equal({}, ConditionalSets.clocked(nil))
      request = Struct.new(:ip, :session_flags, :time).new('1.2.3.4', ['x'], noon)
      assert_equal({ ip: '1.2.3.4', session_flags: ['x'], time: noon }, ConditionalSets.clocked(request))
    end

    test 'the documented resolver in a job: strict mode keeps the muting sets, otherwise each set is evaluated' do
      conditional = ConditionalSets.of(@sets)
      job = { ip: nil, session_flags: [], time: Time.current.change(hour: 12) }

      assert_nil conditional.variant(job), 'noon: the lockdown (22-6) fails, the others cannot pass'
      assert_equal [@lockdown.id], conditional.variant(job.merge(time: Time.current.change(hour: 23))).ids

      PermissionForge.configuration.conditional_sets_strict_mode = true
      assert_equal [@lockdown.id], conditional.variant(job).ids, 'strict: the muting set applies, whatever the hour'
      assert_equal :strict, conditional.serve(job).signature
    end

    # A condition the row holds but nobody can judge — an IP entry that is
    # not one, the same hour twice, one hour of the two — is unjudgeable in
    # every mode: a muting set applies (a lockdown that never locked is the
    # defect), a granting set never passes. The context does not matter.
    test 'a muting set with a broken condition applies in every mode; a granting one never passes' do
      broken_ip = stored(name: 'Broken IP lockdown', is_muting: true, allowed_ips: '10.0.0.0/8, office')
      one_hour = stored(name: 'One hour lockdown', is_muting: true, allowed_hours_start: 22, allowed_hours_end: nil)
      same_hour = stored(name: 'Same hour lockdown', is_muting: true, allowed_hours_start: 9, allowed_hours_end: 9)
      broken_grant = stored(name: 'Broken grant', allowed_ips: 'office')
      conditional = ConditionalSets.of([@plain, broken_ip, one_hour, same_hour, broken_grant])
      muting_ids = [broken_ip.id, one_hour.id, same_hour.id].sort

      [false, true].each do |strict|
        PermissionForge.configuration.conditional_sets_strict_mode = strict
        office = { ip: '10.1.2.3', session_flags: [], time: Time.current.change(hour: 12) }
        elsewhere = office.merge(ip: '203.0.113.9')

        assert_equal muting_ids, conditional.variant(office).ids, "strict=#{strict}, office"
        assert_equal muting_ids, conditional.variant(elsewhere).ids, "strict=#{strict}, elsewhere"
        assert_equal muting_ids, conditional.variant(office.merge(time: Time.current.change(hour: 23))).ids
      end
    end

    test 'a muting set whose IP list was written with newlines applies where an entry matches' do
      lockdown = stored(name: 'Newline lockdown', is_muting: true, allowed_ips: "10.0.0.0/8\n192.168.0.0/16")
      conditional = ConditionalSets.of([@plain, lockdown])

      assert_equal [lockdown.id], conditional.variant(ip: '192.168.4.4', session_flags: []).ids
      assert_nil conditional.variant(ip: '203.0.113.9', session_flags: [])
    end

    # A row as the table holds it, whatever the validations refuse today.
    def stored(**attrs)
      set = create_permission_set(name: attrs.delete(:name))
      set.update_columns(attrs)
      set.reload
    end

    # --- serve / signature ------------------------------------------------------------

    test 'serve remembers the variant and the signature of the context that selected it' do
      conditional = ConditionalSets.of(@sets)
      noon = Time.current.change(hour: 12)
      served = conditional.serve(session_flags: ['mfa_verified'], ip: '203.0.113.1', time: noon)

      assert_same conditional, served.conditional
      assert_equal [@mfa.id], served.variant.ids
      assert served.selected_by?(session_flags: ['mfa_verified'], ip: '203.0.113.1', time: noon + 20.minutes)
      assert_not served.selected_by?(session_flags: ['mfa_verified'], ip: '10.0.0.1', time: noon)
      assert_not served.selected_by?(session_flags: [], ip: '203.0.113.1', time: noon)
      assert_not served.selected_by?(session_flags: ['mfa_verified'], ip: '203.0.113.1', time: noon + 1.hour)
      assert_equal 'user_1_c_1', served.store_key('user_1'), 'the slot of the MFA set (bit 0)'
      assert_equal 'user_1', conditional.serve({ ip: '203.0.113.1', time: noon }).store_key('user_1'), 'nothing passes: the base'
    end

    test 'the signature shares neither the flags array nor a flag with the context' do
      flag = +'mfa_verified'
      flags = [flag]
      served = ConditionalSets.of(@sets).serve(session_flags: flags, ip: '203.0.113.1')
      assert served.selected_by?(session_flags: ['mfa_verified'], ip: '203.0.113.1')

      flag.replace('nope')
      assert_not served.selected_by?(session_flags: flags, ip: '203.0.113.1')

      flags.clear
      assert_not served.selected_by?(session_flags: flags, ip: '203.0.113.1')
    end

    # CS-3: in strict mode no flags at all and an empty list select differently.
    test 'the signature tells a context without session flags from one with none set' do
      served = ConditionalSets.of(@sets).serve(ip: '203.0.113.1', session_flags: [])

      assert served.selected_by?(ip: '203.0.113.1', session_flags: [])
      assert_not served.selected_by?(ip: '203.0.113.1')
    end

    test 'a conditional set and what it serves survive Marshal' do
      served = ConditionalSets.of(@sets).serve(session_flags: ['mfa_verified'], ip: '203.0.113.1')

      copy = Marshal.load(Marshal.dump(served))

      assert_equal served, copy
      assert_equal served.store_key('k'), copy.store_key('k')
    end
  end
end

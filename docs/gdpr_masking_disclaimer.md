# PermissionForge Masking: Obfuscation vs. GDPR Anonymization

## Important Disclaimer

PermissionForge's field masking provides **display-level obfuscation only**. It is designed to limit casual exposure of sensitive data in application reads and UI responses, not to satisfy GDPR data protection requirements.

## Mask Strategies and Their Limitations

| Strategy | Example Input | Example Output | Limitation |
|----------|--------------|----------------|------------|
| `full` | `John Smith` | `********` | Always eight asterisks, so the length is hidden; the original remains in the database unencrypted |
| `email` | `john@example.com` | `j***@example.com` | Preserves domain and first character — re-identifiable with minimal effort. A value without `@` gets the `full` mask |
| `last4` | `+1234567890` | `*******7890` | Last 4 characters visible, and one asterisk per hidden character, so the length is revealed. Values of 4 characters or fewer get the `full` mask |
| `first1_last4` | `John Smith` | `J*****mith` | First character and last 4 visible, length revealed. Values of 5 characters or fewer get the `full` mask |

No strategy masks an empty value: `nil` stays `nil` and `""` stays `""` under every strategy (`MaskValue` returns them unchanged; a custom strategy is not called for them), so a masked field still shows whether a value is present. Every other value is masked as a String (`to_s`).

## Where Masking Is (and Isn't) Enforced

Since v0.9.0 the [`MaskedAttributes` concern](masked-attributes.md) auto-applies to every model with a `Resource` record, so masking covers direct model reads (`customer.email`), `attributes`, and `as_json`/`to_json` serialization — in addition to hash filtering via `FiltersResponseAttributes`. It does **not** cover paths that bypass ActiveRecord's attribute readers: `pluck`, raw SQL (`connection.execute`), or direct database access. The unmasked originals always remain in the database.

## What This Does NOT Satisfy

PermissionForge masking does **NOT** constitute:

- **GDPR Anonymization** (see Recital 26) — Masked data is not irreversibly anonymized. The original values remain in the database and can be accessed by users with unmasked permissions or direct database access.
- **GDPR Pseudonymization** (Art. 4(5)) — No separation of identifiers from data occurs. There is no key management or re-identification control.
- **Right to Erasure** (Art. 17) — Masking does not delete data. Data subject deletion requests require separate data deletion workflows. `DataSubjectErasure` removes the person's assignments and memberships and clears their name snapshots in the audit log, in the current tenant when one is set (`assignments_remaining_elsewhere` counts the rest) and in every tenant when none is; it records `erasure.performed`. The person's id stays in the events (with IPs, `reason` and `data` snapshots) and in the `created_by_id` / `updated_by_id` / `reviewed_by_id` / `sensitive_acknowledged_by_id` columns of live rows; copies already forwarded are not reached; it does not touch your application data. See [what remains after an erasure](audit-log.md#erasure-and-the-names-in-the-log).
- **Data Minimization** (Art. 5(1)(c)) — Masking at the display layer does not reduce the data stored. The full values remain in your database.

## Log-Level Parameter Filtering

PermissionForge can also redact sensitive fields from **Rails logs and error reporters** by integrating with `Rails.application.config.filter_parameters`. This is a separate layer from display masking — it protects ops engineers, log aggregators, and error trackers from accidentally seeing PII in request parameters.

### Automatic (enabled by default)

Both flags default to `true`, so the integration is active out of the box. Set `filter_parameters_integration = false` to opt out:

```ruby
# config/initializers/permission_forge.rb
PermissionForge.configure do |config|
  config.gdpr_defaults = true                  # required — patterns come from gdpr_field_patterns
  config.filter_parameters_integration = true  # appends GDPR patterns at boot
end
```

### Manual (one-liner)

```ruby
# config/initializers/filter_parameter_logging.rb
Rails.application.config.filter_parameters += PermissionForge.gdpr_filter_parameters
```

Both approaches use the same `gdpr_field_patterns` regexes, ensuring a **single source of truth** for which fields are considered sensitive. Note that `PermissionForge.gdpr_filter_parameters` returns an empty array when `gdpr_defaults` is `false` — the manual one-liner depends on it too.

> **Note:** This filters request *parameters* in logs. It does not affect database-level storage, display/response masking (which is handled by the `MaskedAttributes` concern and `FiltersResponseAttributes`), or data deletion. It is one layer in a defense-in-depth strategy.

## Measures to Combine with Masking

Masking is one measure; combine it with:

1. **Encryption at rest** — Use database-level or application-level encryption (e.g., `ActiveRecord::Encryption`, `attr_encrypted`, or transparent database encryption).
2. **Data deletion workflows** — Implement right-to-erasure processes that permanently remove personal data from your database. PermissionForge ships `DataSubjectErasure` to remove its *own* permission data for a user; your application data needs its own workflow.
3. **Pseudonymization** — Use hashing or tokenization with separate key storage for data that must be retained but de-identified.
4. **Access logging** — Add `:field_read` to `config.audit_runtime_events` to store a `field.access` event for every record read through the model (names of the hidden, masked and unconfigured fields, never values), or subscribe to it. It records reads that go through PermissionForge's attribute readers and response filters, not `pluck`, raw SQL or database access. See the [audit log guide](audit-log.md#runtime-groups-and-their-cost) for the volume. `on_field_filtered` still works as a hook with its old signature.
5. **Data retention policies** — Automatically purge personal data after its retention period expires.

## Email Masking: Domain Preservation Risk

The `email` mask strategy outputs `j***@example.com` — the domain is visible. Combined with username lists or organizational knowledge, this could enable re-identification.

**Recommendation:** For external-facing APIs or high-sensitivity environments, use the `full` strategy for email fields instead:

```ruby
PermissionForge::ResourceField.create!(
  resource: resource, name: 'email', label: 'Email',
  read_access: true, mask_access: true, mask_strategy: 'full'
)
```

Or register a custom strategy that also masks the domain:

```ruby
config.custom_mask_strategies = {
  'email_full' => ->(value) { value.present? ? '***@***.***' : '********' }
}
```

The default `email` strategy is acceptable for internal admin UIs where the domain is not sensitive.

## When Masking Is Appropriate

PermissionForge masking is appropriate for:

- Limiting casual exposure in admin UIs (e.g., support agents see `j***@example.com` instead of the full email)
- Reducing the blast radius of screen-sharing or shoulder-surfing
- Implementing least-privilege display patterns in multi-role applications
- Providing an additional layer of defense-in-depth alongside encryption and access controls

## References

- [GDPR Art. 4(5) — Definition of pseudonymization](https://gdpr-info.eu/art-4-gdpr/)
- [GDPR Art. 17 — Right to erasure](https://gdpr-info.eu/art-17-gdpr/)
- [GDPR Art. 25 — Data protection by design and by default](https://gdpr-info.eu/art-25-gdpr/)

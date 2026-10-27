\set ON_ERROR_STOP on
SET search_path TO app, extensions, public;

INSERT INTO bookings(
    id, booking_code, property_id, source_channel, stay_type, status,
    check_in_date, check_out_date, guest_name, guest_phone, guest_email,
    guest_snapshot, property_snapshot, contract_term_snapshot,
    price_unit, duration_value, unit_price_snapshot, subtotal_amount,
    discount_amount, fee_amount, tax_amount, total_amount, currency,
    price_breakdown, policy_snapshot, created_by_account_type,
    created_by_account_id, assigned_admin_user_id
) VALUES
(
    '11111111-1111-4111-8111-111111111111', 'AUTHZ-OWN',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'ADMIN_PORTAL', 'SHORT_TERM', 'CONFIRMED',
    current_date + 7, current_date + 9, 'Scoped fixture', '0000000000', 'fixture@vistay.local',
    '{}'::jsonb, '{}'::jsonb, '{}'::jsonb,
    'NIGHT', 2, 500000, 1000000, 0, 0, 0, 1000000, 'VND',
    '{}'::jsonb, '{}'::jsonb, 'ADMIN', :'target_account_id'::uuid, NULL
),
(
    '22222222-2222-4222-8222-222222222222', 'AUTHZ-ASSIGNED',
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'ADMIN_PORTAL', 'SHORT_TERM', 'CONFIRMED',
    current_date + 10, current_date + 12, 'Assigned fixture', '0000000000', 'fixture@vistay.local',
    '{}'::jsonb, '{}'::jsonb, '{}'::jsonb,
    'NIGHT', 2, 600000, 1200000, 0, 0, 0, 1200000, 'VND',
    '{}'::jsonb, '{}'::jsonb, 'ADMIN', :'maker_account_id'::uuid, :'target_profile_id'::uuid
),
(
    '33333333-3333-4333-8333-333333333333', 'AUTHZ-UNRELATED',
    'cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'ADMIN_PORTAL', 'SHORT_TERM', 'CONFIRMED',
    current_date + 14, current_date + 16, 'Unrelated fixture', '0000000000', 'fixture@vistay.local',
    '{}'::jsonb, '{}'::jsonb, '{}'::jsonb,
    'NIGHT', 2, 700000, 1400000, 0, 0, 0, 1400000, 'VND',
    '{}'::jsonb, '{}'::jsonb, 'ADMIN', :'maker_account_id'::uuid, NULL
)
ON CONFLICT (id) DO UPDATE SET
    created_by_account_id = EXCLUDED.created_by_account_id,
    assigned_admin_user_id = EXCLUDED.assigned_admin_user_id,
    updated_at = now();

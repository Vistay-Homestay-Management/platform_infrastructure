\set ON_ERROR_STOP on

BEGIN;
SET LOCAL search_path TO app, extensions, public;

CREATE TEMP TABLE inventory_fixture_properties (property_id uuid PRIMARY KEY) ON COMMIT DROP;
INSERT INTO inventory_fixture_properties(property_id)
SELECT ('61000000-0000-4000-8000-' || right('000000000000' || value::text, 12))::uuid
FROM generate_series(1, 10) AS value;

-- Remove only the reserved local fixture outcomes. Command evidence must be
-- removed before its referenced blocks; no production/shared IDs are matched.
DELETE FROM inventory_block_commands
WHERE property_id IN (SELECT property_id FROM inventory_fixture_properties);

DELETE FROM command_idempotency
WHERE resource_id IN (
    SELECT id FROM inventory_blocks
    WHERE property_id IN (SELECT property_id FROM inventory_fixture_properties)
);

DELETE FROM inventory_blocks
WHERE property_id IN (SELECT property_id FROM inventory_fixture_properties);

DELETE FROM bookings
WHERE id = '72000000-0000-4000-8000-000000000001';

INSERT INTO bookings (
    id, booking_code, property_id, source_channel, stay_type, status,
    check_in_date, check_out_date, guest_name, guest_phone,
    guest_snapshot, property_snapshot, contract_term_snapshot,
    price_unit, duration_value, unit_price_snapshot, subtotal_amount,
    discount_amount, fee_amount, tax_amount, total_amount, currency,
    price_breakdown, policy_snapshot, created_by_account_type
)
VALUES (
    '72000000-0000-4000-8000-000000000001',
    'PM-INV-BOOKING-001',
    '61000000-0000-4000-8000-000000000002',
    'ADMIN_PORTAL',
    'SHORT_TERM',
    'HELD',
    '2027-06-10',
    '2027-06-13',
    'Local Fixture Guest',
    '+84000000000',
    '{"fixture":true}'::jsonb,
    '{"propertyId":"61000000-0000-4000-8000-000000000002","fixture":true}'::jsonb,
    '{}'::jsonb,
    'NIGHT',
    3,
    1000000,
    3000000,
    0,
    0,
    0,
    3000000,
    'VND',
    '{"fixture":true}'::jsonb,
    '{}'::jsonb,
    'SYSTEM'
);

INSERT INTO inventory_blocks (
    id, property_id, booking_id, block_type, status,
    start_date, end_date_exclusive, reason, released_at,
    channel_provider, channel_external_block_id, version, created_at, updated_at
)
VALUES
    (
        '71000000-0000-4000-8000-000000000001',
        '61000000-0000-4000-8000-000000000002',
        '72000000-0000-4000-8000-000000000001',
        'BOOKING', 'TENTATIVE', '2027-06-10', '2027-06-13',
        'Deterministic tentative booking fixture', NULL, NULL, NULL, 0,
        '2027-01-01T00:00:01Z', '2027-01-01T00:00:01Z'
    ),
    (
        '71000000-0000-4000-8000-000000000002',
        '61000000-0000-4000-8000-000000000003',
        NULL, 'MAINTENANCE', 'ACTIVE', '2027-06-09', '2027-06-14',
        'Deterministic active maintenance fixture', NULL, NULL, NULL, 0,
        '2027-01-01T00:00:02Z', '2027-01-01T00:00:02Z'
    ),
    (
        '71000000-0000-4000-8000-000000000003',
        '61000000-0000-4000-8000-000000000004',
        NULL, 'CHANNEL', 'ACTIVE', '2027-06-11', '2027-06-12',
        'Deterministic channel fixture', NULL, 'CHANNEX', 'pm-inventory-channel-001', 0,
        '2027-01-01T00:00:03Z', '2027-01-01T00:00:03Z'
    ),
    (
        '71000000-0000-4000-8000-000000000004',
        '61000000-0000-4000-8000-000000000005',
        NULL, 'MAINTENANCE', 'RELEASED', '2027-06-09', '2027-06-11',
        'Deterministic released history fixture', '2027-01-02T00:00:00Z', NULL, NULL, 1,
        '2027-01-01T00:00:04Z', '2027-01-02T00:00:00Z'
    ),
    (
        '71000000-0000-4000-8000-000000000005',
        '61000000-0000-4000-8000-000000000005',
        NULL, 'CLEANING', 'CANCELLED', '2027-06-11', '2027-06-14',
        'Deterministic cancelled history fixture', '2027-01-03T00:00:00Z', NULL, NULL, 1,
        '2027-01-01T00:00:05Z', '2027-01-03T00:00:00Z'
    ),
    (
        '71000000-0000-4000-8000-000000000006',
        '61000000-0000-4000-8000-000000000006',
        NULL, 'OWNER_USE', 'ACTIVE', '2027-06-08', '2027-06-10',
        'Deterministic left-adjacent fixture', NULL, NULL, NULL, 0,
        '2027-01-01T00:00:06Z', '2027-01-01T00:00:06Z'
    ),
    (
        '71000000-0000-4000-8000-000000000007',
        '61000000-0000-4000-8000-000000000006',
        NULL, 'MANUAL', 'ACTIVE', '2027-06-13', '2027-06-15',
        'Deterministic right-adjacent fixture', NULL, NULL, NULL, 0,
        '2027-01-01T00:00:07Z', '2027-01-01T00:00:07Z'
    ),
    (
        '71000000-0000-4000-8000-000000000011',
        '61000000-0000-4000-8000-000000000010',
        NULL, 'MAINTENANCE', 'ACTIVE', '2027-01-05', '2027-01-07',
        'Management fixture active maintenance', NULL, NULL, NULL, 0,
        '2027-01-05T08:00:00Z', '2027-01-05T08:00:00Z'
    ),
    (
        '71000000-0000-4000-8000-000000000012',
        '61000000-0000-4000-8000-000000000010',
        NULL, 'CLEANING', 'RELEASED', '2027-01-10', '2027-01-11',
        'Management fixture released cleaning', '2027-01-11T09:00:00Z', NULL, NULL, 1,
        '2027-01-10T08:00:00Z', '2027-01-11T09:00:00Z'
    ),
    (
        '71000000-0000-4000-8000-000000000013',
        '61000000-0000-4000-8000-000000000010',
        NULL, 'OWNER_USE', 'CANCELLED', '2027-02-01', '2027-02-03',
        'Management fixture cancelled owner use', '2027-02-01T10:00:00Z', NULL, NULL, 1,
        '2027-02-01T08:00:00Z', '2027-02-01T10:00:00Z'
    ),
    (
        '71000000-0000-4000-8000-000000000014',
        '61000000-0000-4000-8000-000000000010',
        NULL, 'CHANNEL', 'ACTIVE', '2027-03-01', '2027-03-05',
        'Management fixture active channel', NULL, 'CHANNEX', 'pm-inventory-management-001', 0,
        '2027-03-01T08:00:00Z', '2027-03-01T08:00:00Z'
    );

-- Reset only disposable fixture revisions so repeated runs have identical
-- expected values. Revision 0 is represented by absence of a row.
DELETE FROM inventory_property_revisions
WHERE property_id IN (SELECT property_id FROM inventory_fixture_properties);

INSERT INTO inventory_property_revisions(property_id, revision, updated_at)
VALUES
    ('61000000-0000-4000-8000-000000000002', 1, '2027-01-01T00:00:01Z'),
    ('61000000-0000-4000-8000-000000000003', 1, '2027-01-01T00:00:02Z'),
    ('61000000-0000-4000-8000-000000000004', 1, '2027-01-01T00:00:03Z'),
    ('61000000-0000-4000-8000-000000000005', 2, '2027-01-03T00:00:00Z'),
    ('61000000-0000-4000-8000-000000000006', 2, '2027-01-01T00:00:07Z'),
    ('61000000-0000-4000-8000-000000000010', 4, '2027-03-01T08:00:00Z');

COMMIT;

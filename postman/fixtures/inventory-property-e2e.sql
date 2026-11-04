\set ON_ERROR_STOP on

BEGIN;
SET LOCAL search_path TO app, extensions, public;

-- Reserved local-only topology for the inventory Postman/Newman flow.
INSERT INTO cities (id, code, name, active)
VALUES ('60000000-0000-4000-8000-000000000100', 'PM-INV-CITY', 'Postman Inventory City', true)
ON CONFLICT (id) DO UPDATE
SET code = EXCLUDED.code, name = EXCLUDED.name, active = true, updated_at = now();

INSERT INTO areas (id, city_id, code, name, active)
VALUES (
    '60000000-0000-4000-8000-000000000200',
    '60000000-0000-4000-8000-000000000100',
    'PM-INV-AREA',
    'Postman Inventory Area',
    true
)
ON CONFLICT (id) DO UPDATE
SET city_id = EXCLUDED.city_id, code = EXCLUDED.code, name = EXCLUDED.name,
    active = true, updated_at = now();

INSERT INTO buildings (
    id, area_id, code, name, address_line, time_zone_id, active
)
VALUES (
    '60000000-0000-4000-8000-000000000300',
    '60000000-0000-4000-8000-000000000200',
    'PM-INV-BUILDING',
    'Postman Inventory Building',
    'Local fixture - never production',
    'Asia/Ho_Chi_Minh',
    true
)
ON CONFLICT (id) DO UPDATE
SET area_id = EXCLUDED.area_id, code = EXCLUDED.code, name = EXCLUDED.name,
    address_line = EXCLUDED.address_line, time_zone_id = EXCLUDED.time_zone_id,
    active = true, updated_at = now();

INSERT INTO operating_branches (id, code, name, active, version)
VALUES
    ('60000000-0000-4000-8000-000000000001', 'PM-INV-ALLOWED', 'Postman Inventory Allowed Branch', true, 1),
    ('60000000-0000-4000-8000-000000000002', 'PM-INV-FOREIGN', 'Postman Inventory Foreign Branch', true, 1)
ON CONFLICT (id) DO UPDATE
SET code = EXCLUDED.code, name = EXCLUDED.name, active = true,
    version = EXCLUDED.version, updated_at = now();

INSERT INTO properties (
    id, building_id, code, name, floor_label, unit_number,
    operating_model, property_type, capacity, base_price_per_night,
    currency, operational_status, active
)
SELECT
    fixture.id,
    '60000000-0000-4000-8000-000000000300'::uuid,
    fixture.code,
    fixture.name,
    'POSTMAN',
    fixture.unit_number,
    'OWNED',
    'APARTMENT',
    2,
    1000000,
    'VND',
    'ACTIVE',
    true
FROM (VALUES
    ('61000000-0000-4000-8000-000000000001'::uuid, 'PM-INV-AVAILABLE', 'Postman Available Unit', '01'),
    ('61000000-0000-4000-8000-000000000002'::uuid, 'PM-INV-BOOKING', 'Postman Booking Blocked Unit', '02'),
    ('61000000-0000-4000-8000-000000000003'::uuid, 'PM-INV-MAINT', 'Postman Maintenance Blocked Unit', '03'),
    ('61000000-0000-4000-8000-000000000004'::uuid, 'PM-INV-CHANNEL', 'Postman Channel Blocked Unit', '04'),
    ('61000000-0000-4000-8000-000000000005'::uuid, 'PM-INV-HISTORY', 'Postman History Unit', '05'),
    ('61000000-0000-4000-8000-000000000006'::uuid, 'PM-INV-ADJACENT', 'Postman Adjacent Unit', '06'),
    ('61000000-0000-4000-8000-000000000007'::uuid, 'PM-INV-FOREIGN', 'Postman Foreign Branch Unit', '07'),
    ('61000000-0000-4000-8000-000000000008'::uuid, 'PM-INV-UNMAPPED', 'Postman Unmapped Unit', '08'),
    ('61000000-0000-4000-8000-000000000009'::uuid, 'PM-INV-COMMAND', 'Postman Command Unit', '09'),
    ('61000000-0000-4000-8000-000000000010'::uuid, 'PM-INV-MANAGEMENT', 'Postman Management Unit', '10')
) AS fixture(id, code, name, unit_number)
ON CONFLICT (id) DO UPDATE
SET building_id = EXCLUDED.building_id, code = EXCLUDED.code, name = EXCLUDED.name,
    floor_label = EXCLUDED.floor_label, unit_number = EXCLUDED.unit_number,
    operating_model = EXCLUDED.operating_model, property_type = EXCLUDED.property_type,
    capacity = EXCLUDED.capacity, base_price_per_night = EXCLUDED.base_price_per_night,
    currency = EXCLUDED.currency, operational_status = EXCLUDED.operational_status,
    active = true, updated_at = now();

DELETE FROM property_branch_memberships
WHERE property_id BETWEEN
    '61000000-0000-4000-8000-000000000001'::uuid AND
    '61000000-0000-4000-8000-000000000010'::uuid;

INSERT INTO property_branch_memberships (
    id, property_id, branch_id, membership_version, effective_from, reason
)
SELECT
    ('62000000-0000-4000-8000-' || right('000000000000' || fixture.ordinal::text, 12))::uuid,
    fixture.property_id,
    fixture.branch_id,
    fixture.membership_version,
    '2026-01-01T00:00:00Z'::timestamptz,
    'Deterministic local Postman inventory fixture'
FROM (VALUES
    (1, '61000000-0000-4000-8000-000000000001'::uuid, '60000000-0000-4000-8000-000000000001'::uuid, 7::bigint),
    (2, '61000000-0000-4000-8000-000000000002'::uuid, '60000000-0000-4000-8000-000000000001'::uuid, 7::bigint),
    (3, '61000000-0000-4000-8000-000000000003'::uuid, '60000000-0000-4000-8000-000000000001'::uuid, 7::bigint),
    (4, '61000000-0000-4000-8000-000000000004'::uuid, '60000000-0000-4000-8000-000000000001'::uuid, 7::bigint),
    (5, '61000000-0000-4000-8000-000000000005'::uuid, '60000000-0000-4000-8000-000000000001'::uuid, 7::bigint),
    (6, '61000000-0000-4000-8000-000000000006'::uuid, '60000000-0000-4000-8000-000000000001'::uuid, 7::bigint),
    (7, '61000000-0000-4000-8000-000000000007'::uuid, '60000000-0000-4000-8000-000000000002'::uuid, 3::bigint),
    (9, '61000000-0000-4000-8000-000000000009'::uuid, '60000000-0000-4000-8000-000000000001'::uuid, 7::bigint),
    (10, '61000000-0000-4000-8000-000000000010'::uuid, '60000000-0000-4000-8000-000000000001'::uuid, 7::bigint)
) AS fixture(ordinal, property_id, branch_id, membership_version);

COMMIT;
